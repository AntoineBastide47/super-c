// The wasm instruction encoder: a code buffer, the LEB128 forms, the value types and the opcodes the code
// generator writes. A field a relocation rewrites is a padded 5-byte LEB (`uleb5`, `sleb5`), as the
// linking conventions require.

/// Value types and the empty block type.
pub(package) const I32: u8 = 0x7F;
pub(package) const I64: u8 = 0x7E;
pub(package) const F32: u8 = 0x7D;
pub(package) const F64: u8 = 0x7C;
pub(package) const V128: u8 = 0x7B;
pub(package) const FUNCREF: u8 = 0x70;
pub(package) const BLOCK_EMPTY: u8 = 0x40;

/// Relocation types (`R_WASM_*`, the codes of the linking conventions).
pub(package) const R_FUNCTION_INDEX_LEB: u8 = 0;
pub(package) const R_TABLE_INDEX_SLEB: u8 = 1;
pub(package) const R_TABLE_INDEX_I32: u8 = 2;
pub(package) const R_MEMORY_ADDR_LEB: u8 = 3;
pub(package) const R_MEMORY_ADDR_SLEB: u8 = 4;
pub(package) const R_MEMORY_ADDR_I32: u8 = 5;
pub(package) const R_TYPE_INDEX_LEB: u8 = 6;
pub(package) const R_GLOBAL_INDEX_LEB: u8 = 7;
pub(package) const R_FUNCTION_OFFSET_I32: u8 = 8;
pub(package) const R_SECTION_OFFSET_I32: u8 = 9;
pub(package) const R_GLOBAL_INDEX_I32: u8 = 13;
pub(package) const R_TABLE_NUMBER_LEB: u8 = 20;

/// Whether relocation type `k` carries an addend.
pub(package) const fn has_addend(k: u8) bool {
    return k == R_MEMORY_ADDR_LEB || k == R_MEMORY_ADDR_SLEB || k == R_MEMORY_ADDR_I32 || k == R_FUNCTION_OFFSET_I32 || k == R_SECTION_OFFSET_I32;
}

// Control.
pub(package) const UNREACHABLE: u8 = 0x00;
pub(package) const NOP: u8 = 0x01;
pub(package) const BLOCK: u8 = 0x02;
pub(package) const LOOP: u8 = 0x03;
pub(package) const IF: u8 = 0x04;
pub(package) const ELSE: u8 = 0x05;
pub(package) const END: u8 = 0x0B;
pub(package) const BR: u8 = 0x0C;
pub(package) const BR_IF: u8 = 0x0D;
pub(package) const BR_TABLE: u8 = 0x0E;
pub(package) const RETURN: u8 = 0x0F;
pub(package) const CALL: u8 = 0x10;
pub(package) const CALL_INDIRECT: u8 = 0x11;
pub(package) const DROP: u8 = 0x1A;
pub(package) const SELECT: u8 = 0x1B;
pub(package) const SELECT_T: u8 = 0x1C;
// Variables.
pub(package) const LOCAL_GET: u8 = 0x20;
pub(package) const LOCAL_SET: u8 = 0x21;
pub(package) const LOCAL_TEE: u8 = 0x22;
pub(package) const GLOBAL_GET: u8 = 0x23;
pub(package) const GLOBAL_SET: u8 = 0x24;
// Memory.
pub(package) const I32_LOAD: u8 = 0x28;
pub(package) const I64_LOAD: u8 = 0x29;
pub(package) const F32_LOAD: u8 = 0x2A;
pub(package) const F64_LOAD: u8 = 0x2B;
pub(package) const I32_LOAD8_S: u8 = 0x2C;
pub(package) const I32_LOAD8_U: u8 = 0x2D;
pub(package) const I32_LOAD16_S: u8 = 0x2E;
pub(package) const I32_LOAD16_U: u8 = 0x2F;
pub(package) const I64_LOAD8_S: u8 = 0x30;
pub(package) const I64_LOAD8_U: u8 = 0x31;
pub(package) const I64_LOAD16_S: u8 = 0x32;
pub(package) const I64_LOAD16_U: u8 = 0x33;
pub(package) const I64_LOAD32_S: u8 = 0x34;
pub(package) const I64_LOAD32_U: u8 = 0x35;
pub(package) const I32_STORE: u8 = 0x36;
pub(package) const I64_STORE: u8 = 0x37;
pub(package) const F32_STORE: u8 = 0x38;
pub(package) const F64_STORE: u8 = 0x39;
pub(package) const I32_STORE8: u8 = 0x3A;
pub(package) const I32_STORE16: u8 = 0x3B;
pub(package) const I64_STORE8: u8 = 0x3C;
pub(package) const I64_STORE16: u8 = 0x3D;
pub(package) const I64_STORE32: u8 = 0x3E;
// Constants.
pub(package) const I32_CONST: u8 = 0x41;
pub(package) const I64_CONST: u8 = 0x42;
pub(package) const F32_CONST: u8 = 0x43;
pub(package) const F64_CONST: u8 = 0x44;
// i32 comparisons; the i64 ones are 0x50.. in the same order, after `eqz`.
pub(package) const I32_EQZ: u8 = 0x45;
pub(package) const I32_EQ: u8 = 0x46;
pub(package) const I32_NE: u8 = 0x47;
pub(package) const I32_LT_S: u8 = 0x48;
pub(package) const I32_LT_U: u8 = 0x49;
pub(package) const I32_GT_S: u8 = 0x4A;
pub(package) const I32_GT_U: u8 = 0x4B;
pub(package) const I32_LE_S: u8 = 0x4C;
pub(package) const I32_LE_U: u8 = 0x4D;
pub(package) const I32_GE_S: u8 = 0x4E;
pub(package) const I32_GE_U: u8 = 0x4F;
pub(package) const I64_EQZ: u8 = 0x50;
pub(package) const I64_EQ: u8 = 0x51;
pub(package) const I64_NE: u8 = 0x52;
pub(package) const I64_LT_S: u8 = 0x53;
pub(package) const I64_LT_U: u8 = 0x54;
pub(package) const I64_GT_S: u8 = 0x55;
pub(package) const I64_GT_U: u8 = 0x56;
pub(package) const I64_LE_S: u8 = 0x57;
pub(package) const I64_LE_U: u8 = 0x58;
pub(package) const I64_GE_S: u8 = 0x59;
pub(package) const I64_GE_U: u8 = 0x5A;
// Float comparisons: eq, ne, lt, gt, le, ge; the f64 ones are 0x61.. .
pub(package) const F32_EQ: u8 = 0x5B;
pub(package) const F32_NE: u8 = 0x5C;
pub(package) const F32_LT: u8 = 0x5D;
pub(package) const F32_GT: u8 = 0x5E;
pub(package) const F32_LE: u8 = 0x5F;
pub(package) const F32_GE: u8 = 0x60;
pub(package) const F64_EQ: u8 = 0x61;
pub(package) const F64_NE: u8 = 0x62;
pub(package) const F64_LT: u8 = 0x63;
pub(package) const F64_GT: u8 = 0x64;
pub(package) const F64_LE: u8 = 0x65;
pub(package) const F64_GE: u8 = 0x66;
// i32 arithmetic; the i64 forms are 0x79.. in the same order.
pub(package) const I32_CLZ: u8 = 0x67;
pub(package) const I32_CTZ: u8 = 0x68;
pub(package) const I32_POPCNT: u8 = 0x69;
pub(package) const I32_ADD: u8 = 0x6A;
pub(package) const I32_SUB: u8 = 0x6B;
pub(package) const I32_MUL: u8 = 0x6C;
pub(package) const I32_DIV_S: u8 = 0x6D;
pub(package) const I32_DIV_U: u8 = 0x6E;
pub(package) const I32_REM_S: u8 = 0x6F;
pub(package) const I32_REM_U: u8 = 0x70;
pub(package) const I32_AND: u8 = 0x71;
pub(package) const I32_OR: u8 = 0x72;
pub(package) const I32_XOR: u8 = 0x73;
pub(package) const I32_SHL: u8 = 0x74;
pub(package) const I32_SHR_S: u8 = 0x75;
pub(package) const I32_SHR_U: u8 = 0x76;
pub(package) const I32_ROTL: u8 = 0x77;
pub(package) const I32_ROTR: u8 = 0x78;
pub(package) const I64_CLZ: u8 = 0x79;
pub(package) const I64_CTZ: u8 = 0x7A;
pub(package) const I64_POPCNT: u8 = 0x7B;
pub(package) const I64_ADD: u8 = 0x7C;
pub(package) const I64_SUB: u8 = 0x7D;
pub(package) const I64_MUL: u8 = 0x7E;
pub(package) const I64_DIV_S: u8 = 0x7F;
pub(package) const I64_DIV_U: u8 = 0x80;
pub(package) const I64_REM_S: u8 = 0x81;
pub(package) const I64_REM_U: u8 = 0x82;
pub(package) const I64_AND: u8 = 0x83;
pub(package) const I64_OR: u8 = 0x84;
pub(package) const I64_XOR: u8 = 0x85;
pub(package) const I64_SHL: u8 = 0x86;
pub(package) const I64_SHR_S: u8 = 0x87;
pub(package) const I64_SHR_U: u8 = 0x88;
pub(package) const I64_ROTL: u8 = 0x89;
pub(package) const I64_ROTR: u8 = 0x8A;
// Float arithmetic; the f64 forms are 0x99.. in the same order.
pub(package) const F32_ABS: u8 = 0x8B;
pub(package) const F32_NEG: u8 = 0x8C;
pub(package) const F32_CEIL: u8 = 0x8D;
pub(package) const F32_FLOOR: u8 = 0x8E;
pub(package) const F32_TRUNC: u8 = 0x8F;
pub(package) const F32_NEAREST: u8 = 0x90;
pub(package) const F32_SQRT: u8 = 0x91;
pub(package) const F32_ADD: u8 = 0x92;
pub(package) const F32_SUB: u8 = 0x93;
pub(package) const F32_MUL: u8 = 0x94;
pub(package) const F32_DIV: u8 = 0x95;
pub(package) const F32_MIN: u8 = 0x96;
pub(package) const F32_MAX: u8 = 0x97;
pub(package) const F32_COPYSIGN: u8 = 0x98;
pub(package) const F64_ABS: u8 = 0x99;
pub(package) const F64_NEG: u8 = 0x9A;
pub(package) const F64_CEIL: u8 = 0x9B;
pub(package) const F64_FLOOR: u8 = 0x9C;
pub(package) const F64_TRUNC: u8 = 0x9D;
pub(package) const F64_NEAREST: u8 = 0x9E;
pub(package) const F64_SQRT: u8 = 0x9F;
pub(package) const F64_ADD: u8 = 0xA0;
pub(package) const F64_SUB: u8 = 0xA1;
pub(package) const F64_MUL: u8 = 0xA2;
pub(package) const F64_DIV: u8 = 0xA3;
pub(package) const F64_MIN: u8 = 0xA4;
pub(package) const F64_MAX: u8 = 0xA5;
pub(package) const F64_COPYSIGN: u8 = 0xA6;
// Conversions.
pub(package) const I32_WRAP_I64: u8 = 0xA7;
pub(package) const I32_TRUNC_F32_S: u8 = 0xA8;
pub(package) const I32_TRUNC_F32_U: u8 = 0xA9;
pub(package) const I32_TRUNC_F64_S: u8 = 0xAA;
pub(package) const I32_TRUNC_F64_U: u8 = 0xAB;
pub(package) const I64_EXTEND_I32_S: u8 = 0xAC;
pub(package) const I64_EXTEND_I32_U: u8 = 0xAD;
pub(package) const I64_TRUNC_F32_S: u8 = 0xAE;
pub(package) const I64_TRUNC_F32_U: u8 = 0xAF;
pub(package) const I64_TRUNC_F64_S: u8 = 0xB0;
pub(package) const I64_TRUNC_F64_U: u8 = 0xB1;
pub(package) const F32_CONVERT_I32_S: u8 = 0xB2;
pub(package) const F32_CONVERT_I32_U: u8 = 0xB3;
pub(package) const F32_CONVERT_I64_S: u8 = 0xB4;
pub(package) const F32_CONVERT_I64_U: u8 = 0xB5;
pub(package) const F32_DEMOTE_F64: u8 = 0xB6;
pub(package) const F64_CONVERT_I32_S: u8 = 0xB7;
pub(package) const F64_CONVERT_I32_U: u8 = 0xB8;
pub(package) const F64_CONVERT_I64_S: u8 = 0xB9;
pub(package) const F64_CONVERT_I64_U: u8 = 0xBA;
pub(package) const F64_PROMOTE_F32: u8 = 0xBB;
pub(package) const I32_REINTERPRET_F32: u8 = 0xBC;
pub(package) const I64_REINTERPRET_F64: u8 = 0xBD;
pub(package) const F32_REINTERPRET_I32: u8 = 0xBE;
pub(package) const F64_REINTERPRET_I64: u8 = 0xBF;
// Sign extension (the sign-ext feature).
pub(package) const I32_EXTEND8_S: u8 = 0xC0;
pub(package) const I32_EXTEND16_S: u8 = 0xC1;
pub(package) const I64_EXTEND8_S: u8 = 0xC2;
pub(package) const I64_EXTEND16_S: u8 = 0xC3;
pub(package) const I64_EXTEND32_S: u8 = 0xC4;
// The vector prefix and the v128 forms the calling convention needs (the simd128 feature).
pub(package) const SIMD: u8 = 0xFD;
pub(package) const V128_LOAD: u32 = 0x00;
pub(package) const V128_STORE: u32 = 0x0B;

/// The bytes of one function body or data segment, and the relocations it holds.
pub(package) struct Code {
    pub(package) bytes: Vector<u8>,
}

extend Code {
    pub(package) fn new() Code {
        return Code { bytes: Vector::<u8>::new() };
    }

    pub(package) fn clear(self: &mut Self) {
        self.bytes.truncate(0);
    }

    pub(package) const fn len(self: &Self) u32 {
        return self.bytes.len() as u32;
    }

    pub(package) fn op(self: &mut Self, x: u8) {
        self.bytes.push(x);
    }

    /// `x` as an unsigned LEB128.
    pub(package) fn uleb(self: &mut Self, x0: u64) {
        uleb(&mut self.bytes, x0);
    }

    /// `x` as a signed LEB128.
    pub(package) fn sleb(self: &mut Self, x: i64) {
        sleb(&mut self.bytes, x);
    }

    /// `x` as an unsigned LEB128 padded to 5 bytes: the field a relocation rewrites.
    pub(package) fn uleb5(self: &mut Self, x: u32) {
        uleb5(&mut self.bytes, x);
    }

    /// `x` as a signed LEB128 padded to 5 bytes.
    pub(package) fn sleb5(self: &mut Self, x: i32) {
        let u = x as u32;
        for k in 0..4u32 {
            self.bytes.push((u >> 7 * k & 0x7F) as u8 | 0x80);
        }
        // The fifth byte holds bits 28 to 31, sign-extended to its 7 bits.
        self.bytes.push((x >> 28 & 0x7F) as u8);
    }

    /// A 32-bit little-endian word.
    pub(package) fn u32le(self: &mut Self, x: u32) {
        for k in 0..4u32 {
            self.bytes.push((x >> 8 * k & 0xFF) as u8);
        }
    }

    /// A 64-bit little-endian word.
    pub(package) fn u64le(self: &mut Self, x: u64) {
        self.u32le(x as u32);
        self.u32le((x >> 32) as u32);
    }

    /// A memory instruction's immediate: log2 of its alignment and its offset.
    pub(package) fn memarg(self: &mut Self, align_log2: u32, off: u32) {
        self.uleb(align_log2);
        self.uleb(off);
    }

    /// `local.get`, `local.set` or `local.tee` (`op`) of local `k`.
    pub(package) fn local(self: &mut Self, op: u8, k: u32) {
        self.bytes.push(op);
        self.uleb(k);
    }

    pub(package) fn i32_const(self: &mut Self, x: i32) {
        self.bytes.push(I32_CONST);
        self.sleb(x);
    }

    pub(package) fn i64_const(self: &mut Self, x: i64) {
        self.bytes.push(I64_CONST);
        self.sleb(x);
    }

    pub(package) fn f32_const(self: &mut Self, bits: u32) {
        self.bytes.push(F32_CONST);
        self.u32le(bits);
    }

    pub(package) fn f64_const(self: &mut Self, bits: u64) {
        self.bytes.push(F64_CONST);
        self.u64le(bits);
    }

    /// A vector instruction: the prefix, then its code.
    pub(package) fn simd(self: &mut Self, code: u32) {
        self.bytes.push(SIMD);
        self.uleb(code);
    }
}

/// Append `x0` to `o` as an unsigned LEB128.
pub(package) fn uleb(o: &mut Vector<u8>, x0: u64) {
    let mut x = x0;
    // At most 10 bytes: each takes 7 bits.
    for _ in 0..10 {
        let b = (x & 0x7F) as u8;
        x = x >> 7;
        if x == 0 {
            o.push(b);
            return;
        }
        o.push(b | 0x80);
    }
}

/// Append `x0` to `o` as a signed LEB128.
pub(package) fn sleb(o: &mut Vector<u8>, x0: i64) {
    let mut x = x0;
    // At most 10 bytes: each takes 7 bits.
    for _ in 0..10 {
        let b = (x & 0x7F) as u8;
        x = x >> 7;
        if x == 0 && (b & 0x40) == 0 || x == -1 && (b & 0x40) != 0 {
            o.push(b);
            return;
        }
        o.push(b | 0x80);
    }
}

/// Append `x` to `o` as an unsigned LEB128 padded to 5 bytes.
pub(package) fn uleb5(o: &mut Vector<u8>, x: u32) {
    for k in 0..4u32 {
        o.push((x >> 7 * k & 0x7F) as u8 | 0x80);
    }
    o.push((x >> 28 & 0x0F) as u8);
}

/// Rewrite the 5-byte unsigned LEB at `at` of `o` to hold `x`.
pub(package) fn patch_uleb5(o: &mut Vector<u8>, at: usize, x: u32) {
    for k in 0..4u32 {
        o.set(at + k as usize, (x >> 7 * k & 0x7F) as u8 | 0x80);
    }
    o.set(at + 4, (x >> 28 & 0x0F) as u8);
}

/// Append name `s` to `o`: its length, then its bytes.
pub(package) fn name(o: &mut Vector<u8>, s: str) {
    uleb(o, s.len() as u64);
    for i in 0..s.len() {
        o.push(s.byte_at(i));
    }
}
