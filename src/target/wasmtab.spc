// The wasm instruction table: one row per instruction, read by the assembler and the disassembler
// (`wasmasm`) and checked against every instruction the code generator (`wasmgen`) emits. A row is a
// mnemonic (LLVM's assembly syntax), the opcode (a prefix byte, 0xFC or 0xFD, and its LEB code; else
// one byte), the immediates' kind and a memory access's natural alignment. An instruction is a row and
// its immediates; it encodes to bytes and decodes back, a relocated field in a padded 5-byte LEB.
import target::wasm as w;

pub(package) struct Row {
    pub(package) mn: str<'static>,
    pub(package) pfx: u8,
    pub(package) code: u32,
    pub(package) imm: u8, // `K::*`
    pub(package) al: u8, // the natural alignment's log2 of a memory access
}

extend Row as Copy {}

/// Immediate kinds.
pub(package) struct K {}

extend K {
    pub(package) const NONE: u8 = 0;
    pub(package) const BT: u8 = 1; // a block type: empty or one value type
    pub(package) const LABEL: u8 = 2; // a branch depth
    pub(package) const BRTABLE: u8 = 3; // depths, the default last
    pub(package) const FUNC: u8 = 4; // a function index
    pub(package) const CALLI: u8 = 5; // a type index and a table index
    pub(package) const LOCAL: u8 = 6;
    pub(package) const GLOBAL: u8 = 7;
    pub(package) const MEM: u8 = 8; // an alignment's log2 and an offset
    pub(package) const I32: u8 = 9;
    pub(package) const I64: u8 = 10;
    pub(package) const F32: u8 = 11; // the bits
    pub(package) const F64: u8 = 12;
    pub(package) const MEMIDX: u8 = 13; // memory 0
    pub(package) const MEMIDX2: u8 = 14; // memories 0 and 0
    pub(package) const V128: u8 = 15; // 16 bytes
    pub(package) const SHUF: u8 = 16; // 16 lane indices
    pub(package) const LANE: u8 = 17;
    pub(package) const MEMLANE: u8 = 18; // an alignment, an offset and a lane
    pub(package) const SEG: u8 = 19; // a data segment index
    pub(package) const SEGMEM: u8 = 20; // a data segment index and memory 0
}

const fn r(mn: str<'static>, pfx: u8, code: u32, imm: u8, al: u8) Row {
    return Row { mn: mn, pfx: pfx, code: code, imm: imm, al: al };
}

pub(package) const ROWS: [Row; 452] = [
    r("unreachable", 0x00, 0x0, K::NONE, 0),
    r("nop", 0x00, 0x1, K::NONE, 0),
    r("block", 0x00, 0x2, K::BT, 0),
    r("loop", 0x00, 0x3, K::BT, 0),
    r("if", 0x00, 0x4, K::BT, 0),
    r("else", 0x00, 0x5, K::NONE, 0),
    r("end_block", 0x00, 0xB, K::NONE, 0),
    r("end_loop", 0x00, 0xB, K::NONE, 0),
    r("end_if", 0x00, 0xB, K::NONE, 0),
    r("end_function", 0x00, 0xB, K::NONE, 0),
    r("end", 0x00, 0xB, K::NONE, 0),
    r("br", 0x00, 0xC, K::LABEL, 0),
    r("br_if", 0x00, 0xD, K::LABEL, 0),
    r("br_table", 0x00, 0xE, K::BRTABLE, 0),
    r("return", 0x00, 0xF, K::NONE, 0),
    r("call", 0x00, 0x10, K::FUNC, 0),
    r("call_indirect", 0x00, 0x11, K::CALLI, 0),
    r("drop", 0x00, 0x1A, K::NONE, 0),
    r("i32.select", 0x00, 0x1B, K::NONE, 0),
    r("i64.select", 0x00, 0x1B, K::NONE, 0),
    r("f32.select", 0x00, 0x1B, K::NONE, 0),
    r("f64.select", 0x00, 0x1B, K::NONE, 0),
    r("local.get", 0x00, 0x20, K::LOCAL, 0),
    r("local.set", 0x00, 0x21, K::LOCAL, 0),
    r("local.tee", 0x00, 0x22, K::LOCAL, 0),
    r("global.get", 0x00, 0x23, K::GLOBAL, 0),
    r("global.set", 0x00, 0x24, K::GLOBAL, 0),
    r("i32.load", 0x00, 0x28, K::MEM, 2),
    r("i64.load", 0x00, 0x29, K::MEM, 3),
    r("f32.load", 0x00, 0x2A, K::MEM, 2),
    r("f64.load", 0x00, 0x2B, K::MEM, 3),
    r("i32.load8_s", 0x00, 0x2C, K::MEM, 0),
    r("i32.load8_u", 0x00, 0x2D, K::MEM, 0),
    r("i32.load16_s", 0x00, 0x2E, K::MEM, 1),
    r("i32.load16_u", 0x00, 0x2F, K::MEM, 1),
    r("i64.load8_s", 0x00, 0x30, K::MEM, 0),
    r("i64.load8_u", 0x00, 0x31, K::MEM, 0),
    r("i64.load16_s", 0x00, 0x32, K::MEM, 1),
    r("i64.load16_u", 0x00, 0x33, K::MEM, 1),
    r("i64.load32_s", 0x00, 0x34, K::MEM, 2),
    r("i64.load32_u", 0x00, 0x35, K::MEM, 2),
    r("i32.store", 0x00, 0x36, K::MEM, 2),
    r("i64.store", 0x00, 0x37, K::MEM, 3),
    r("f32.store", 0x00, 0x38, K::MEM, 2),
    r("f64.store", 0x00, 0x39, K::MEM, 3),
    r("i32.store8", 0x00, 0x3A, K::MEM, 0),
    r("i32.store16", 0x00, 0x3B, K::MEM, 1),
    r("i64.store8", 0x00, 0x3C, K::MEM, 0),
    r("i64.store16", 0x00, 0x3D, K::MEM, 1),
    r("i64.store32", 0x00, 0x3E, K::MEM, 2),
    r("memory.size", 0x00, 0x3F, K::MEMIDX, 0),
    r("memory.grow", 0x00, 0x40, K::MEMIDX, 0),
    r("i32.const", 0x00, 0x41, K::I32, 0),
    r("i64.const", 0x00, 0x42, K::I64, 0),
    r("f32.const", 0x00, 0x43, K::F32, 0),
    r("f64.const", 0x00, 0x44, K::F64, 0),
    r("i32.eqz", 0x00, 0x45, K::NONE, 0),
    r("i32.eq", 0x00, 0x46, K::NONE, 0),
    r("i32.ne", 0x00, 0x47, K::NONE, 0),
    r("i32.lt_s", 0x00, 0x48, K::NONE, 0),
    r("i32.lt_u", 0x00, 0x49, K::NONE, 0),
    r("i32.gt_s", 0x00, 0x4A, K::NONE, 0),
    r("i32.gt_u", 0x00, 0x4B, K::NONE, 0),
    r("i32.le_s", 0x00, 0x4C, K::NONE, 0),
    r("i32.le_u", 0x00, 0x4D, K::NONE, 0),
    r("i32.ge_s", 0x00, 0x4E, K::NONE, 0),
    r("i32.ge_u", 0x00, 0x4F, K::NONE, 0),
    r("i64.eqz", 0x00, 0x50, K::NONE, 0),
    r("i64.eq", 0x00, 0x51, K::NONE, 0),
    r("i64.ne", 0x00, 0x52, K::NONE, 0),
    r("i64.lt_s", 0x00, 0x53, K::NONE, 0),
    r("i64.lt_u", 0x00, 0x54, K::NONE, 0),
    r("i64.gt_s", 0x00, 0x55, K::NONE, 0),
    r("i64.gt_u", 0x00, 0x56, K::NONE, 0),
    r("i64.le_s", 0x00, 0x57, K::NONE, 0),
    r("i64.le_u", 0x00, 0x58, K::NONE, 0),
    r("i64.ge_s", 0x00, 0x59, K::NONE, 0),
    r("i64.ge_u", 0x00, 0x5A, K::NONE, 0),
    r("f32.eq", 0x00, 0x5B, K::NONE, 0),
    r("f32.ne", 0x00, 0x5C, K::NONE, 0),
    r("f32.lt", 0x00, 0x5D, K::NONE, 0),
    r("f32.gt", 0x00, 0x5E, K::NONE, 0),
    r("f32.le", 0x00, 0x5F, K::NONE, 0),
    r("f32.ge", 0x00, 0x60, K::NONE, 0),
    r("f64.eq", 0x00, 0x61, K::NONE, 0),
    r("f64.ne", 0x00, 0x62, K::NONE, 0),
    r("f64.lt", 0x00, 0x63, K::NONE, 0),
    r("f64.gt", 0x00, 0x64, K::NONE, 0),
    r("f64.le", 0x00, 0x65, K::NONE, 0),
    r("f64.ge", 0x00, 0x66, K::NONE, 0),
    r("i32.clz", 0x00, 0x67, K::NONE, 0),
    r("i32.ctz", 0x00, 0x68, K::NONE, 0),
    r("i32.popcnt", 0x00, 0x69, K::NONE, 0),
    r("i32.add", 0x00, 0x6A, K::NONE, 0),
    r("i32.sub", 0x00, 0x6B, K::NONE, 0),
    r("i32.mul", 0x00, 0x6C, K::NONE, 0),
    r("i32.div_s", 0x00, 0x6D, K::NONE, 0),
    r("i32.div_u", 0x00, 0x6E, K::NONE, 0),
    r("i32.rem_s", 0x00, 0x6F, K::NONE, 0),
    r("i32.rem_u", 0x00, 0x70, K::NONE, 0),
    r("i32.and", 0x00, 0x71, K::NONE, 0),
    r("i32.or", 0x00, 0x72, K::NONE, 0),
    r("i32.xor", 0x00, 0x73, K::NONE, 0),
    r("i32.shl", 0x00, 0x74, K::NONE, 0),
    r("i32.shr_s", 0x00, 0x75, K::NONE, 0),
    r("i32.shr_u", 0x00, 0x76, K::NONE, 0),
    r("i32.rotl", 0x00, 0x77, K::NONE, 0),
    r("i32.rotr", 0x00, 0x78, K::NONE, 0),
    r("i64.clz", 0x00, 0x79, K::NONE, 0),
    r("i64.ctz", 0x00, 0x7A, K::NONE, 0),
    r("i64.popcnt", 0x00, 0x7B, K::NONE, 0),
    r("i64.add", 0x00, 0x7C, K::NONE, 0),
    r("i64.sub", 0x00, 0x7D, K::NONE, 0),
    r("i64.mul", 0x00, 0x7E, K::NONE, 0),
    r("i64.div_s", 0x00, 0x7F, K::NONE, 0),
    r("i64.div_u", 0x00, 0x80, K::NONE, 0),
    r("i64.rem_s", 0x00, 0x81, K::NONE, 0),
    r("i64.rem_u", 0x00, 0x82, K::NONE, 0),
    r("i64.and", 0x00, 0x83, K::NONE, 0),
    r("i64.or", 0x00, 0x84, K::NONE, 0),
    r("i64.xor", 0x00, 0x85, K::NONE, 0),
    r("i64.shl", 0x00, 0x86, K::NONE, 0),
    r("i64.shr_s", 0x00, 0x87, K::NONE, 0),
    r("i64.shr_u", 0x00, 0x88, K::NONE, 0),
    r("i64.rotl", 0x00, 0x89, K::NONE, 0),
    r("i64.rotr", 0x00, 0x8A, K::NONE, 0),
    r("f32.abs", 0x00, 0x8B, K::NONE, 0),
    r("f32.neg", 0x00, 0x8C, K::NONE, 0),
    r("f32.ceil", 0x00, 0x8D, K::NONE, 0),
    r("f32.floor", 0x00, 0x8E, K::NONE, 0),
    r("f32.trunc", 0x00, 0x8F, K::NONE, 0),
    r("f32.nearest", 0x00, 0x90, K::NONE, 0),
    r("f32.sqrt", 0x00, 0x91, K::NONE, 0),
    r("f32.add", 0x00, 0x92, K::NONE, 0),
    r("f32.sub", 0x00, 0x93, K::NONE, 0),
    r("f32.mul", 0x00, 0x94, K::NONE, 0),
    r("f32.div", 0x00, 0x95, K::NONE, 0),
    r("f32.min", 0x00, 0x96, K::NONE, 0),
    r("f32.max", 0x00, 0x97, K::NONE, 0),
    r("f32.copysign", 0x00, 0x98, K::NONE, 0),
    r("f64.abs", 0x00, 0x99, K::NONE, 0),
    r("f64.neg", 0x00, 0x9A, K::NONE, 0),
    r("f64.ceil", 0x00, 0x9B, K::NONE, 0),
    r("f64.floor", 0x00, 0x9C, K::NONE, 0),
    r("f64.trunc", 0x00, 0x9D, K::NONE, 0),
    r("f64.nearest", 0x00, 0x9E, K::NONE, 0),
    r("f64.sqrt", 0x00, 0x9F, K::NONE, 0),
    r("f64.add", 0x00, 0xA0, K::NONE, 0),
    r("f64.sub", 0x00, 0xA1, K::NONE, 0),
    r("f64.mul", 0x00, 0xA2, K::NONE, 0),
    r("f64.div", 0x00, 0xA3, K::NONE, 0),
    r("f64.min", 0x00, 0xA4, K::NONE, 0),
    r("f64.max", 0x00, 0xA5, K::NONE, 0),
    r("f64.copysign", 0x00, 0xA6, K::NONE, 0),
    r("i32.wrap_i64", 0x00, 0xA7, K::NONE, 0),
    r("i32.trunc_f32_s", 0x00, 0xA8, K::NONE, 0),
    r("i32.trunc_f32_u", 0x00, 0xA9, K::NONE, 0),
    r("i32.trunc_f64_s", 0x00, 0xAA, K::NONE, 0),
    r("i32.trunc_f64_u", 0x00, 0xAB, K::NONE, 0),
    r("i64.extend_i32_s", 0x00, 0xAC, K::NONE, 0),
    r("i64.extend_i32_u", 0x00, 0xAD, K::NONE, 0),
    r("i64.trunc_f32_s", 0x00, 0xAE, K::NONE, 0),
    r("i64.trunc_f32_u", 0x00, 0xAF, K::NONE, 0),
    r("i64.trunc_f64_s", 0x00, 0xB0, K::NONE, 0),
    r("i64.trunc_f64_u", 0x00, 0xB1, K::NONE, 0),
    r("f32.convert_i32_s", 0x00, 0xB2, K::NONE, 0),
    r("f32.convert_i32_u", 0x00, 0xB3, K::NONE, 0),
    r("f32.convert_i64_s", 0x00, 0xB4, K::NONE, 0),
    r("f32.convert_i64_u", 0x00, 0xB5, K::NONE, 0),
    r("f32.demote_f64", 0x00, 0xB6, K::NONE, 0),
    r("f64.convert_i32_s", 0x00, 0xB7, K::NONE, 0),
    r("f64.convert_i32_u", 0x00, 0xB8, K::NONE, 0),
    r("f64.convert_i64_s", 0x00, 0xB9, K::NONE, 0),
    r("f64.convert_i64_u", 0x00, 0xBA, K::NONE, 0),
    r("f64.promote_f32", 0x00, 0xBB, K::NONE, 0),
    r("i32.reinterpret_f32", 0x00, 0xBC, K::NONE, 0),
    r("i64.reinterpret_f64", 0x00, 0xBD, K::NONE, 0),
    r("f32.reinterpret_i32", 0x00, 0xBE, K::NONE, 0),
    r("f64.reinterpret_i64", 0x00, 0xBF, K::NONE, 0),
    r("i32.extend8_s", 0x00, 0xC0, K::NONE, 0),
    r("i32.extend16_s", 0x00, 0xC1, K::NONE, 0),
    r("i64.extend8_s", 0x00, 0xC2, K::NONE, 0),
    r("i64.extend16_s", 0x00, 0xC3, K::NONE, 0),
    r("i64.extend32_s", 0x00, 0xC4, K::NONE, 0),
    r("i32.trunc_sat_f32_s", 0xFC, 0x0, K::NONE, 0),
    r("i32.trunc_sat_f32_u", 0xFC, 0x1, K::NONE, 0),
    r("i32.trunc_sat_f64_s", 0xFC, 0x2, K::NONE, 0),
    r("i32.trunc_sat_f64_u", 0xFC, 0x3, K::NONE, 0),
    r("i64.trunc_sat_f32_s", 0xFC, 0x4, K::NONE, 0),
    r("i64.trunc_sat_f32_u", 0xFC, 0x5, K::NONE, 0),
    r("i64.trunc_sat_f64_s", 0xFC, 0x6, K::NONE, 0),
    r("i64.trunc_sat_f64_u", 0xFC, 0x7, K::NONE, 0),
    r("memory.init", 0xFC, 0x8, K::SEGMEM, 0),
    r("data.drop", 0xFC, 0x9, K::SEG, 0),
    r("memory.copy", 0xFC, 0xA, K::MEMIDX2, 0),
    r("memory.fill", 0xFC, 0xB, K::MEMIDX, 0),
    r("v128.load", 0xFD, 0x0, K::MEM, 4),
    r("i16x8.load8x8_s", 0xFD, 0x1, K::MEM, 3),
    r("i16x8.load8x8_u", 0xFD, 0x2, K::MEM, 3),
    r("i32x4.load16x4_s", 0xFD, 0x3, K::MEM, 3),
    r("i32x4.load16x4_u", 0xFD, 0x4, K::MEM, 3),
    r("i64x2.load32x2_s", 0xFD, 0x5, K::MEM, 3),
    r("i64x2.load32x2_u", 0xFD, 0x6, K::MEM, 3),
    r("v128.load8_splat", 0xFD, 0x7, K::MEM, 0),
    r("v128.load16_splat", 0xFD, 0x8, K::MEM, 1),
    r("v128.load32_splat", 0xFD, 0x9, K::MEM, 2),
    r("v128.load64_splat", 0xFD, 0xA, K::MEM, 3),
    r("v128.store", 0xFD, 0xB, K::MEM, 4),
    r("v128.const", 0xFD, 0xC, K::V128, 0),
    r("i8x16.shuffle", 0xFD, 0xD, K::SHUF, 0),
    r("i8x16.swizzle", 0xFD, 0xE, K::NONE, 0),
    r("i8x16.splat", 0xFD, 0xF, K::NONE, 0),
    r("i16x8.splat", 0xFD, 0x10, K::NONE, 0),
    r("i32x4.splat", 0xFD, 0x11, K::NONE, 0),
    r("i64x2.splat", 0xFD, 0x12, K::NONE, 0),
    r("f32x4.splat", 0xFD, 0x13, K::NONE, 0),
    r("f64x2.splat", 0xFD, 0x14, K::NONE, 0),
    r("i8x16.extract_lane_s", 0xFD, 0x15, K::LANE, 0),
    r("i8x16.extract_lane_u", 0xFD, 0x16, K::LANE, 0),
    r("i8x16.replace_lane", 0xFD, 0x17, K::LANE, 0),
    r("i16x8.extract_lane_s", 0xFD, 0x18, K::LANE, 0),
    r("i16x8.extract_lane_u", 0xFD, 0x19, K::LANE, 0),
    r("i16x8.replace_lane", 0xFD, 0x1A, K::LANE, 0),
    r("i32x4.extract_lane", 0xFD, 0x1B, K::LANE, 0),
    r("i32x4.replace_lane", 0xFD, 0x1C, K::LANE, 0),
    r("i64x2.extract_lane", 0xFD, 0x1D, K::LANE, 0),
    r("i64x2.replace_lane", 0xFD, 0x1E, K::LANE, 0),
    r("f32x4.extract_lane", 0xFD, 0x1F, K::LANE, 0),
    r("f32x4.replace_lane", 0xFD, 0x20, K::LANE, 0),
    r("f64x2.extract_lane", 0xFD, 0x21, K::LANE, 0),
    r("f64x2.replace_lane", 0xFD, 0x22, K::LANE, 0),
    r("i8x16.eq", 0xFD, 0x23, K::NONE, 0),
    r("i8x16.ne", 0xFD, 0x24, K::NONE, 0),
    r("i8x16.lt_s", 0xFD, 0x25, K::NONE, 0),
    r("i8x16.lt_u", 0xFD, 0x26, K::NONE, 0),
    r("i8x16.gt_s", 0xFD, 0x27, K::NONE, 0),
    r("i8x16.gt_u", 0xFD, 0x28, K::NONE, 0),
    r("i8x16.le_s", 0xFD, 0x29, K::NONE, 0),
    r("i8x16.le_u", 0xFD, 0x2A, K::NONE, 0),
    r("i8x16.ge_s", 0xFD, 0x2B, K::NONE, 0),
    r("i8x16.ge_u", 0xFD, 0x2C, K::NONE, 0),
    r("i16x8.eq", 0xFD, 0x2D, K::NONE, 0),
    r("i16x8.ne", 0xFD, 0x2E, K::NONE, 0),
    r("i16x8.lt_s", 0xFD, 0x2F, K::NONE, 0),
    r("i16x8.lt_u", 0xFD, 0x30, K::NONE, 0),
    r("i16x8.gt_s", 0xFD, 0x31, K::NONE, 0),
    r("i16x8.gt_u", 0xFD, 0x32, K::NONE, 0),
    r("i16x8.le_s", 0xFD, 0x33, K::NONE, 0),
    r("i16x8.le_u", 0xFD, 0x34, K::NONE, 0),
    r("i16x8.ge_s", 0xFD, 0x35, K::NONE, 0),
    r("i16x8.ge_u", 0xFD, 0x36, K::NONE, 0),
    r("i32x4.eq", 0xFD, 0x37, K::NONE, 0),
    r("i32x4.ne", 0xFD, 0x38, K::NONE, 0),
    r("i32x4.lt_s", 0xFD, 0x39, K::NONE, 0),
    r("i32x4.lt_u", 0xFD, 0x3A, K::NONE, 0),
    r("i32x4.gt_s", 0xFD, 0x3B, K::NONE, 0),
    r("i32x4.gt_u", 0xFD, 0x3C, K::NONE, 0),
    r("i32x4.le_s", 0xFD, 0x3D, K::NONE, 0),
    r("i32x4.le_u", 0xFD, 0x3E, K::NONE, 0),
    r("i32x4.ge_s", 0xFD, 0x3F, K::NONE, 0),
    r("i32x4.ge_u", 0xFD, 0x40, K::NONE, 0),
    r("f32x4.eq", 0xFD, 0x41, K::NONE, 0),
    r("f32x4.ne", 0xFD, 0x42, K::NONE, 0),
    r("f32x4.lt", 0xFD, 0x43, K::NONE, 0),
    r("f32x4.gt", 0xFD, 0x44, K::NONE, 0),
    r("f32x4.le", 0xFD, 0x45, K::NONE, 0),
    r("f32x4.ge", 0xFD, 0x46, K::NONE, 0),
    r("f64x2.eq", 0xFD, 0x47, K::NONE, 0),
    r("f64x2.ne", 0xFD, 0x48, K::NONE, 0),
    r("f64x2.lt", 0xFD, 0x49, K::NONE, 0),
    r("f64x2.gt", 0xFD, 0x4A, K::NONE, 0),
    r("f64x2.le", 0xFD, 0x4B, K::NONE, 0),
    r("f64x2.ge", 0xFD, 0x4C, K::NONE, 0),
    r("v128.not", 0xFD, 0x4D, K::NONE, 0),
    r("v128.and", 0xFD, 0x4E, K::NONE, 0),
    r("v128.andnot", 0xFD, 0x4F, K::NONE, 0),
    r("v128.or", 0xFD, 0x50, K::NONE, 0),
    r("v128.xor", 0xFD, 0x51, K::NONE, 0),
    r("v128.bitselect", 0xFD, 0x52, K::NONE, 0),
    r("v128.any_true", 0xFD, 0x53, K::NONE, 0),
    r("v128.load8_lane", 0xFD, 0x54, K::MEMLANE, 0),
    r("v128.load16_lane", 0xFD, 0x55, K::MEMLANE, 1),
    r("v128.load32_lane", 0xFD, 0x56, K::MEMLANE, 2),
    r("v128.load64_lane", 0xFD, 0x57, K::MEMLANE, 3),
    r("v128.store8_lane", 0xFD, 0x58, K::MEMLANE, 0),
    r("v128.store16_lane", 0xFD, 0x59, K::MEMLANE, 1),
    r("v128.store32_lane", 0xFD, 0x5A, K::MEMLANE, 2),
    r("v128.store64_lane", 0xFD, 0x5B, K::MEMLANE, 3),
    r("v128.load32_zero", 0xFD, 0x5C, K::MEM, 2),
    r("v128.load64_zero", 0xFD, 0x5D, K::MEM, 3),
    r("f32x4.demote_f64x2_zero", 0xFD, 0x5E, K::NONE, 0),
    r("f64x2.promote_low_f32x4", 0xFD, 0x5F, K::NONE, 0),
    r("i8x16.abs", 0xFD, 0x60, K::NONE, 0),
    r("i8x16.neg", 0xFD, 0x61, K::NONE, 0),
    r("i8x16.popcnt", 0xFD, 0x62, K::NONE, 0),
    r("i8x16.all_true", 0xFD, 0x63, K::NONE, 0),
    r("i8x16.bitmask", 0xFD, 0x64, K::NONE, 0),
    r("i8x16.narrow_i16x8_s", 0xFD, 0x65, K::NONE, 0),
    r("i8x16.narrow_i16x8_u", 0xFD, 0x66, K::NONE, 0),
    r("f32x4.ceil", 0xFD, 0x67, K::NONE, 0),
    r("f32x4.floor", 0xFD, 0x68, K::NONE, 0),
    r("f32x4.trunc", 0xFD, 0x69, K::NONE, 0),
    r("f32x4.nearest", 0xFD, 0x6A, K::NONE, 0),
    r("i8x16.shl", 0xFD, 0x6B, K::NONE, 0),
    r("i8x16.shr_s", 0xFD, 0x6C, K::NONE, 0),
    r("i8x16.shr_u", 0xFD, 0x6D, K::NONE, 0),
    r("i8x16.add", 0xFD, 0x6E, K::NONE, 0),
    r("i8x16.add_sat_s", 0xFD, 0x6F, K::NONE, 0),
    r("i8x16.add_sat_u", 0xFD, 0x70, K::NONE, 0),
    r("i8x16.sub", 0xFD, 0x71, K::NONE, 0),
    r("i8x16.sub_sat_s", 0xFD, 0x72, K::NONE, 0),
    r("i8x16.sub_sat_u", 0xFD, 0x73, K::NONE, 0),
    r("f64x2.ceil", 0xFD, 0x74, K::NONE, 0),
    r("f64x2.floor", 0xFD, 0x75, K::NONE, 0),
    r("i8x16.min_s", 0xFD, 0x76, K::NONE, 0),
    r("i8x16.min_u", 0xFD, 0x77, K::NONE, 0),
    r("i8x16.max_s", 0xFD, 0x78, K::NONE, 0),
    r("i8x16.max_u", 0xFD, 0x79, K::NONE, 0),
    r("f64x2.trunc", 0xFD, 0x7A, K::NONE, 0),
    r("i8x16.avgr_u", 0xFD, 0x7B, K::NONE, 0),
    r("i16x8.extadd_pairwise_i8x16_s", 0xFD, 0x7C, K::NONE, 0),
    r("i16x8.extadd_pairwise_i8x16_u", 0xFD, 0x7D, K::NONE, 0),
    r("i32x4.extadd_pairwise_i16x8_s", 0xFD, 0x7E, K::NONE, 0),
    r("i32x4.extadd_pairwise_i16x8_u", 0xFD, 0x7F, K::NONE, 0),
    r("i16x8.abs", 0xFD, 0x80, K::NONE, 0),
    r("i16x8.neg", 0xFD, 0x81, K::NONE, 0),
    r("i16x8.q15mulr_sat_s", 0xFD, 0x82, K::NONE, 0),
    r("i16x8.all_true", 0xFD, 0x83, K::NONE, 0),
    r("i16x8.bitmask", 0xFD, 0x84, K::NONE, 0),
    r("i16x8.narrow_i32x4_s", 0xFD, 0x85, K::NONE, 0),
    r("i16x8.narrow_i32x4_u", 0xFD, 0x86, K::NONE, 0),
    r("i16x8.extend_low_i8x16_s", 0xFD, 0x87, K::NONE, 0),
    r("i16x8.extend_high_i8x16_s", 0xFD, 0x88, K::NONE, 0),
    r("i16x8.extend_low_i8x16_u", 0xFD, 0x89, K::NONE, 0),
    r("i16x8.extend_high_i8x16_u", 0xFD, 0x8A, K::NONE, 0),
    r("i16x8.shl", 0xFD, 0x8B, K::NONE, 0),
    r("i16x8.shr_s", 0xFD, 0x8C, K::NONE, 0),
    r("i16x8.shr_u", 0xFD, 0x8D, K::NONE, 0),
    r("i16x8.add", 0xFD, 0x8E, K::NONE, 0),
    r("i16x8.add_sat_s", 0xFD, 0x8F, K::NONE, 0),
    r("i16x8.add_sat_u", 0xFD, 0x90, K::NONE, 0),
    r("i16x8.sub", 0xFD, 0x91, K::NONE, 0),
    r("i16x8.sub_sat_s", 0xFD, 0x92, K::NONE, 0),
    r("i16x8.sub_sat_u", 0xFD, 0x93, K::NONE, 0),
    r("f64x2.nearest", 0xFD, 0x94, K::NONE, 0),
    r("i16x8.mul", 0xFD, 0x95, K::NONE, 0),
    r("i16x8.min_s", 0xFD, 0x96, K::NONE, 0),
    r("i16x8.min_u", 0xFD, 0x97, K::NONE, 0),
    r("i16x8.max_s", 0xFD, 0x98, K::NONE, 0),
    r("i16x8.max_u", 0xFD, 0x99, K::NONE, 0),
    r("i16x8.avgr_u", 0xFD, 0x9B, K::NONE, 0),
    r("i16x8.extmul_low_i8x16_s", 0xFD, 0x9C, K::NONE, 0),
    r("i16x8.extmul_high_i8x16_s", 0xFD, 0x9D, K::NONE, 0),
    r("i16x8.extmul_low_i8x16_u", 0xFD, 0x9E, K::NONE, 0),
    r("i16x8.extmul_high_i8x16_u", 0xFD, 0x9F, K::NONE, 0),
    r("i32x4.abs", 0xFD, 0xA0, K::NONE, 0),
    r("i32x4.neg", 0xFD, 0xA1, K::NONE, 0),
    r("i32x4.all_true", 0xFD, 0xA3, K::NONE, 0),
    r("i32x4.bitmask", 0xFD, 0xA4, K::NONE, 0),
    r("i32x4.extend_low_i16x8_s", 0xFD, 0xA7, K::NONE, 0),
    r("i32x4.extend_high_i16x8_s", 0xFD, 0xA8, K::NONE, 0),
    r("i32x4.extend_low_i16x8_u", 0xFD, 0xA9, K::NONE, 0),
    r("i32x4.extend_high_i16x8_u", 0xFD, 0xAA, K::NONE, 0),
    r("i32x4.shl", 0xFD, 0xAB, K::NONE, 0),
    r("i32x4.shr_s", 0xFD, 0xAC, K::NONE, 0),
    r("i32x4.shr_u", 0xFD, 0xAD, K::NONE, 0),
    r("i32x4.add", 0xFD, 0xAE, K::NONE, 0),
    r("i32x4.sub", 0xFD, 0xB1, K::NONE, 0),
    r("i32x4.mul", 0xFD, 0xB5, K::NONE, 0),
    r("i32x4.min_s", 0xFD, 0xB6, K::NONE, 0),
    r("i32x4.min_u", 0xFD, 0xB7, K::NONE, 0),
    r("i32x4.max_s", 0xFD, 0xB8, K::NONE, 0),
    r("i32x4.max_u", 0xFD, 0xB9, K::NONE, 0),
    r("i32x4.dot_i16x8_s", 0xFD, 0xBA, K::NONE, 0),
    r("i32x4.extmul_low_i16x8_s", 0xFD, 0xBC, K::NONE, 0),
    r("i32x4.extmul_high_i16x8_s", 0xFD, 0xBD, K::NONE, 0),
    r("i32x4.extmul_low_i16x8_u", 0xFD, 0xBE, K::NONE, 0),
    r("i32x4.extmul_high_i16x8_u", 0xFD, 0xBF, K::NONE, 0),
    r("i64x2.abs", 0xFD, 0xC0, K::NONE, 0),
    r("i64x2.neg", 0xFD, 0xC1, K::NONE, 0),
    r("i64x2.all_true", 0xFD, 0xC3, K::NONE, 0),
    r("i64x2.bitmask", 0xFD, 0xC4, K::NONE, 0),
    r("i64x2.extend_low_i32x4_s", 0xFD, 0xC7, K::NONE, 0),
    r("i64x2.extend_high_i32x4_s", 0xFD, 0xC8, K::NONE, 0),
    r("i64x2.extend_low_i32x4_u", 0xFD, 0xC9, K::NONE, 0),
    r("i64x2.extend_high_i32x4_u", 0xFD, 0xCA, K::NONE, 0),
    r("i64x2.shl", 0xFD, 0xCB, K::NONE, 0),
    r("i64x2.shr_s", 0xFD, 0xCC, K::NONE, 0),
    r("i64x2.shr_u", 0xFD, 0xCD, K::NONE, 0),
    r("i64x2.add", 0xFD, 0xCE, K::NONE, 0),
    r("i64x2.sub", 0xFD, 0xD1, K::NONE, 0),
    r("i64x2.mul", 0xFD, 0xD5, K::NONE, 0),
    r("i64x2.eq", 0xFD, 0xD6, K::NONE, 0),
    r("i64x2.ne", 0xFD, 0xD7, K::NONE, 0),
    r("i64x2.lt_s", 0xFD, 0xD8, K::NONE, 0),
    r("i64x2.gt_s", 0xFD, 0xD9, K::NONE, 0),
    r("i64x2.le_s", 0xFD, 0xDA, K::NONE, 0),
    r("i64x2.ge_s", 0xFD, 0xDB, K::NONE, 0),
    r("i64x2.extmul_low_i32x4_s", 0xFD, 0xDC, K::NONE, 0),
    r("i64x2.extmul_high_i32x4_s", 0xFD, 0xDD, K::NONE, 0),
    r("i64x2.extmul_low_i32x4_u", 0xFD, 0xDE, K::NONE, 0),
    r("i64x2.extmul_high_i32x4_u", 0xFD, 0xDF, K::NONE, 0),
    r("f32x4.abs", 0xFD, 0xE0, K::NONE, 0),
    r("f32x4.neg", 0xFD, 0xE1, K::NONE, 0),
    r("f32x4.sqrt", 0xFD, 0xE3, K::NONE, 0),
    r("f32x4.add", 0xFD, 0xE4, K::NONE, 0),
    r("f32x4.sub", 0xFD, 0xE5, K::NONE, 0),
    r("f32x4.mul", 0xFD, 0xE6, K::NONE, 0),
    r("f32x4.div", 0xFD, 0xE7, K::NONE, 0),
    r("f32x4.min", 0xFD, 0xE8, K::NONE, 0),
    r("f32x4.max", 0xFD, 0xE9, K::NONE, 0),
    r("f32x4.pmin", 0xFD, 0xEA, K::NONE, 0),
    r("f32x4.pmax", 0xFD, 0xEB, K::NONE, 0),
    r("f64x2.abs", 0xFD, 0xEC, K::NONE, 0),
    r("f64x2.neg", 0xFD, 0xED, K::NONE, 0),
    r("f64x2.sqrt", 0xFD, 0xEF, K::NONE, 0),
    r("f64x2.add", 0xFD, 0xF0, K::NONE, 0),
    r("f64x2.sub", 0xFD, 0xF1, K::NONE, 0),
    r("f64x2.mul", 0xFD, 0xF2, K::NONE, 0),
    r("f64x2.div", 0xFD, 0xF3, K::NONE, 0),
    r("f64x2.min", 0xFD, 0xF4, K::NONE, 0),
    r("f64x2.max", 0xFD, 0xF5, K::NONE, 0),
    r("f64x2.pmin", 0xFD, 0xF6, K::NONE, 0),
    r("f64x2.pmax", 0xFD, 0xF7, K::NONE, 0),
    r("i32x4.trunc_sat_f32x4_s", 0xFD, 0xF8, K::NONE, 0),
    r("i32x4.trunc_sat_f32x4_u", 0xFD, 0xF9, K::NONE, 0),
    r("f32x4.convert_i32x4_s", 0xFD, 0xFA, K::NONE, 0),
    r("f32x4.convert_i32x4_u", 0xFD, 0xFB, K::NONE, 0),
    r("i32x4.trunc_sat_f64x2_s_zero", 0xFD, 0xFC, K::NONE, 0),
    r("i32x4.trunc_sat_f64x2_u_zero", 0xFD, 0xFD, K::NONE, 0),
    r("f64x2.convert_low_i32x4_s", 0xFD, 0xFE, K::NONE, 0),
    r("f64x2.convert_low_i32x4_u", 0xFD, 0xFF, K::NONE, 0),
    r("i8x16.relaxed_swizzle", 0xFD, 0x100, K::NONE, 0),
    r("i32x4.relaxed_trunc_f32x4_s", 0xFD, 0x101, K::NONE, 0),
    r("i32x4.relaxed_trunc_f32x4_u", 0xFD, 0x102, K::NONE, 0),
    r("i32x4.relaxed_trunc_f64x2_s_zero", 0xFD, 0x103, K::NONE, 0),
    r("i32x4.relaxed_trunc_f64x2_u_zero", 0xFD, 0x104, K::NONE, 0),
    r("f32x4.relaxed_madd", 0xFD, 0x105, K::NONE, 0),
    r("f32x4.relaxed_nmadd", 0xFD, 0x106, K::NONE, 0),
    r("f64x2.relaxed_madd", 0xFD, 0x107, K::NONE, 0),
    r("f64x2.relaxed_nmadd", 0xFD, 0x108, K::NONE, 0),
    r("i8x16.relaxed_laneselect", 0xFD, 0x109, K::NONE, 0),
    r("i16x8.relaxed_laneselect", 0xFD, 0x10A, K::NONE, 0),
    r("i32x4.relaxed_laneselect", 0xFD, 0x10B, K::NONE, 0),
    r("i64x2.relaxed_laneselect", 0xFD, 0x10C, K::NONE, 0),
    r("f32x4.relaxed_min", 0xFD, 0x10D, K::NONE, 0),
    r("f32x4.relaxed_max", 0xFD, 0x10E, K::NONE, 0),
    r("f64x2.relaxed_min", 0xFD, 0x10F, K::NONE, 0),
    r("f64x2.relaxed_max", 0xFD, 0x110, K::NONE, 0),
    r("i16x8.relaxed_q15mulr_s", 0xFD, 0x111, K::NONE, 0),
    r("i16x8.relaxed_dot_i8x16_i7x16_s", 0xFD, 0x112, K::NONE, 0),
    r("i32x4.relaxed_dot_i8x16_i7x16_add_s", 0xFD, 0x113, K::NONE, 0),
];

// ---- Instructions ----

/// An instruction: its row and immediates. `a`: an index, a depth, a block type, a constant (a float's
/// bits) or an alignment's log2; `b`: an offset or a table index; `lo` and `hi`: 16 bytes, or a lane in
/// `lo`; `wide`: the fields in a padded 5-byte LEB (bit 0 `a`, bit 1 `b`); `targets`: `br_table`'s
/// depths, the default last.
pub(package) struct Ins {
    pub(package) row: u32,
    pub(package) a: i64,
    pub(package) b: i64,
    pub(package) lo: u64,
    pub(package) hi: u64,
    pub(package) wide: u8,
    pub(package) targets: Vector<u32>,
}

extend Ins {
    pub(package) fn new(row: u32) Ins {
        return Ins { row: row, a: 0, b: 0, lo: 0, hi: 0, wide: 0, targets: Vector::<u32>::new() };
    }
}

/// A field of an encoding: its offset from the instruction's start, its size, whether it is a padded
/// LEB.
pub(package) struct Field {
    pub(package) at: u32,
    pub(package) wide: bool,
}

// A 32-bit unsigned field: padded to 5 bytes when `wide`.
fn u32f(out: &mut Vector<u8>, v: i64, wide: bool) bool {
    if v < 0 || v > 0xFFFFFFFF {
        return false;
    }
    if wide {
        w::uleb5(out, v as u32);
    } else {
        w::uleb(out, v as u64);
    }
    return true;
}

// A 32-bit signed field: padded to 5 bytes when `wide`.
fn s32f(out: &mut Vector<u8>, v: i64, wide: bool) bool {
    if v < -0x80000000 || v > 0x7FFFFFFF {
        return false;
    }
    if !wide {
        w::sleb(out, v);
        return true;
    }
    for k in 0..4u32 {
        out.push((v >> 7 * k & 0x7F) as u8 | 0x80);
    }
    out.push((v >> 28 & 0x7F) as u8);
    return true;
}

/// Whether `t` is a block type: empty (0x40) or a value type.
pub(package) const fn block_type(t: i64) bool {
    return t == 0x40 || t == w::I32 || t == w::I64 || t == w::F32 || t == w::F64 || t == w::V128 || t == w::FUNCREF;
}

/// Append the encoding of `n` to `out`; false when an immediate is out of its range. `f` gets the
/// first relocatable field (an index, a constant, an offset), `f2` the second (a call's table).
pub(package) fn encode(n: &Ins, out: &mut Vector<u8>, f: &mut Field, f2: &mut Field) bool {
    let rows: []Row = ROWS;
    let r = rows[n.row as usize];
    let st = out.len();
    if r.pfx != 0 {
        out.push(r.pfx);
        w::uleb(out, r.code);
    } else {
        out.push(r.code as u8);
    }
    f.at = (out.len() - st) as u32;
    f.wide = (n.wide & 1) != 0;
    f2.at = 0;
    f2.wide = false;
    let wa = (n.wide & 1) != 0;
    let wb = (n.wide & 2) != 0;
    switch r.imm {
        K::NONE => {},
        K::BT => {
            if !block_type(n.a) {
                return false;
            }
            out.push(n.a as u8);
        },
        K::LABEL | K::FUNC | K::LOCAL | K::GLOBAL | K::SEG => {
            return u32f(out, n.a, wa);
        },
        K::BRTABLE => {
            if n.targets.len() == 0 {
                return false;
            }
            w::uleb(out, (n.targets.len() - 1) as u64);
            for k in 0..n.targets.len() {
                w::uleb(out, n.targets[k]);
            }
        },
        K::CALLI => {
            if !u32f(out, n.a, wa) {
                return false;
            }
            f2.at = (out.len() - st) as u32;
            f2.wide = wb;
            return u32f(out, n.b, wb);
        },
        K::MEM | K::MEMLANE => {
            if n.a < 0 || n.a > r.al as i64 {
                return false;
            }
            w::uleb(out, n.a as u64);
            f.at = (out.len() - st) as u32;
            f.wide = wb;
            if !u32f(out, n.b, wb) {
                return false;
            }
            if r.imm == K::MEMLANE {
                if n.lo >= 16u64 >> r.al {
                    return false;
                }
                out.push(n.lo as u8);
            }
        },
        K::I32 => {
            return s32f(out, n.a, wa);
        },
        K::I64 => {
            w::sleb(out, n.a);
        },
        K::F32 => {
            if n.a < 0 || n.a > 0xFFFFFFFF {
                return false;
            }
            for k in 0..4u32 {
                out.push((n.a as u64 >> 8 * k & 0xFF) as u8);
            }
        },
        K::F64 => {
            for k in 0..8u32 {
                out.push((n.a as u64 >> 8 * k & 0xFF) as u8);
            }
        },
        K::MEMIDX => {
            out.push(0);
        },
        K::MEMIDX2 => {
            out.push(0);
            out.push(0);
        },
        K::V128 | K::SHUF => {
            for k in 0..16u32 {
                let v = if k < 8 {
                    n.lo >> 8 * k
                } else {
                    n.hi >> 8 * (k - 8)
                };
                if r.imm == K::SHUF && (v & 0xFF) >= 32 {
                    return false;
                }
                out.push((v & 0xFF) as u8);
            }
        },
        K::LANE => {
            if n.a < 0 || n.a >= lanes(r.mn) as i64 {
                return false;
            }
            out.push(n.a as u8);
        },
        K::SEGMEM => {
            if !u32f(out, n.a, wa) {
                return false;
            }
            out.push(0);
        },
        _ => {
            return false;
        },
    }
    return true;
}

/// The lane count of a lane instruction's shape (its mnemonic's first part).
pub(package) const fn lanes(mn: str) u32 {
    if mn.starts_with("i8x16") {
        return 16;
    }
    if mn.starts_with("i16x8") {
        return 8;
    }
    if mn.starts_with("i32x4") || mn.starts_with("f32x4") {
        return 4;
    }
    return 2;
}

// An unsigned LEB at `b[*p..end]`: its value, and whether it took 5 bytes where fewer would do;
// false past `end` or past 10 bytes.
fn get_uleb(b: []u8, p: &mut usize, end: usize, v: &mut u64, padded: &mut bool) bool {
    let st = *p;
    let mut x: u64 = 0;
    for k in 0..10u32 {
        if *p >= end {
            return false;
        }
        let c = b[*p];
        *p += 1;
        x |= (c & 0x7F) as u64 << 7 * k;
        if (c & 0x80) == 0 {
            *v = x;
            let mut tmp = Vector::<u8>::new();
            w::uleb(&mut tmp, x);
            *padded = *p - st != tmp.len();
            return true;
        }
    }
    return false;
}

// A signed LEB at `b[*p..end]`, as `get_uleb`.
fn get_sleb(b: []u8, p: &mut usize, end: usize, v: &mut i64, padded: &mut bool) bool {
    let st = *p;
    let mut x: i64 = 0;
    let mut shift: u32 = 0;
    for _ in 0..10u32 {
        if *p >= end {
            return false;
        }
        let c = b[*p];
        *p += 1;
        x |= (c & 0x7F) as i64 << shift;
        shift += 7;
        if (c & 0x80) == 0 {
            if shift < 64 && (c & 0x40) != 0 {
                x |= -1i64 << shift;
            }
            *v = x;
            let mut tmp = Vector::<u8>::new();
            w::sleb(&mut tmp, x);
            *padded = *p - st != tmp.len();
            return true;
        }
    }
    return false;
}

/// Decode the instruction at `b[at..end]` into `n`: its length, 0 when no row encodes those bytes. A
/// padded LEB of 5 bytes sets its `wide` bit; one of another length does not decode (`encode` gives
/// none).
pub(package) fn decode(b: []u8, at: usize, end: usize, n: &mut Ins) u32 {
    if at >= end {
        return 0;
    }
    let mut p = at;
    let pfx = b[p];
    p += 1;
    let mut code: u64 = pfx;
    let mut pad = false;
    if pfx == 0xFC || pfx == 0xFD {
        if !get_uleb(b, &mut p, end, &mut code, &mut pad) || pad {
            return 0;
        }
    }
    let rows: []Row = ROWS;
    for ri in 0..rows.len() {
        let r = rows[ri];
        let rp: u8 = if pfx == 0xFC || pfx == 0xFD {
            pfx
        } else {
            0u8
        };
        if r.pfx != rp || r.code as u64 != code {
            continue;
        }
        let mut v = Ins::new(ri as u32);
        let mut q = p;
        let mut u: u64 = 0;
        let mut ok = true;
        switch r.imm {
            K::NONE => {},
            K::BT => {
                ok = q < end && block_type(b[q]);
                if ok {
                    v.a = b[q];
                    q += 1;
                }
            },
            K::LABEL | K::FUNC | K::LOCAL | K::GLOBAL | K::SEG | K::SEGMEM => {
                ok = get_uleb(b, &mut q, end, &mut u, &mut pad);
                v.a = u as i64;
                if pad {
                    v.wide |= 1;
                }
                if ok && r.imm == K::SEGMEM {
                    ok = q < end && b[q] == 0;
                    q += 1;
                }
            },
            K::BRTABLE => {
                ok = get_uleb(b, &mut q, end, &mut u, &mut pad) && !pad && u < 0xFFFF;
                let cnt = u + 1;
                let mut k: u64 = 0;
                while ok && k < cnt {
                    ok = get_uleb(b, &mut q, end, &mut u, &mut pad) && !pad;
                    v.targets.push(u as u32);
                    k += 1;
                }
            },
            K::CALLI => {
                ok = get_uleb(b, &mut q, end, &mut u, &mut pad);
                v.a = u as i64;
                if pad {
                    v.wide |= 1;
                }
                ok = ok && get_uleb(b, &mut q, end, &mut u, &mut pad);
                v.b = u as i64;
                if pad {
                    v.wide |= 2;
                }
            },
            K::MEM | K::MEMLANE => {
                ok = get_uleb(b, &mut q, end, &mut u, &mut pad) && !pad;
                v.a = u as i64;
                ok = ok && get_uleb(b, &mut q, end, &mut u, &mut pad);
                v.b = u as i64;
                if pad {
                    v.wide |= 2;
                }
                if ok && r.imm == K::MEMLANE {
                    ok = q < end;
                    if ok {
                        v.lo = b[q];
                        q += 1;
                    }
                }
            },
            K::I32 | K::I64 => {
                let mut s: i64 = 0;
                ok = get_sleb(b, &mut q, end, &mut s, &mut pad);
                v.a = s;
                if pad {
                    v.wide |= 1;
                }
            },
            K::F32 | K::F64 => {
                let nb: usize = if r.imm == K::F32 {
                    4
                } else {
                    8
                };
                ok = q + nb <= end;
                if ok {
                    for k in 0..nb {
                        u |= b[q + k] as u64 << 8 * k as u64;
                    }
                    v.a = u as i64;
                    q += nb;
                }
            },
            K::MEMIDX => {
                ok = q < end && b[q] == 0;
                q += 1;
            },
            K::MEMIDX2 => {
                ok = q + 1 < end && b[q] == 0 && b[q + 1] == 0;
                q += 2;
            },
            K::V128 | K::SHUF => {
                ok = q + 16 <= end;
                if ok {
                    for k in 0..8usize {
                        v.lo |= b[q + k] as u64 << 8 * k as u64;
                        v.hi |= b[q + 8 + k] as u64 << 8 * k as u64;
                    }
                    q += 16;
                }
            },
            K::LANE => {
                ok = q < end;
                if ok {
                    v.a = b[q];
                    q += 1;
                }
            },
            _ => {
                ok = false;
            },
        }
        if !ok {
            return 0;
        }
        // The bytes are this row's encoding of the immediates: a padded field took exactly 5 bytes.
        let mut tmp = Vector::<u8>::with_capacity(q - at);
        let mut f = Field { at: 0, wide: false };
        let mut f2 = Field { at: 0, wide: false };
        if !encode(&v, &mut tmp, &mut f, &mut f2) || tmp.as_slice() != b[at..q] {
            return 0;
        }
        *n = v;
        return (q - at) as u32;
    }
    return 0;
}
