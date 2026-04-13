// std.simd — portable 128-bit SIMD operations.
//
// Vec128 is a 16-byte value type passed in XMM (x86) or NEON (aarch64) registers.
// Operations map to single instructions on both architectures.

import std.test

pub type Vec128 = #simd struct {
    _data: [u8; 16]
}

// Load 16 bytes from a pointer (unaligned).
#foreign pub fn v128_load(ptr: &u8) Vec128

// Broadcast a single byte to all 16 lanes.
#foreign pub fn v128_splat_u8(val: u8) Vec128

// Per-lane equality: result[i] = (a[i] == b[i]) ? 0xFF : 0x00
#foreign pub fn v128_cmpeq_u8(a: Vec128, b: Vec128) Vec128

// Bitwise OR of two vectors.
#foreign pub fn v128_or(a: Vec128, b: Vec128) Vec128

// Bitwise AND of two vectors.
#foreign pub fn v128_and(a: Vec128, b: Vec128) Vec128

// Bitwise AND-NOT: result = ~a & b
#foreign pub fn v128_andnot(a: Vec128, b: Vec128) Vec128

// Count the number of lanes set to 0xFF (non-zero bytes).
// Each 0xFF lane contributes 1 to the count.
#foreign pub fn v128_count_true(a: Vec128) u32

// Extract a bitmask: bit i = 1 if lane i has its high bit set.
// Returns a 16-bit mask as u32.
#foreign pub fn v128_movemask(a: Vec128) u32

// Vector of all zeros.
#foreign pub fn v128_zero() Vec128

// Build a Vec128 from two u64 values: [lo, hi].
#foreign pub fn v128_from_u64x2(lo: u64, hi: u64) Vec128

// Build a Vec128 from four u32 values: [a, b, c, d].
#foreign pub fn v128_from_u32x4(a: u32, b: u32, c: u32, d: u32) Vec128

// Build a Vec128 with a single u64 in the low 64 bits (high 64 bits zeroed).
// Useful for constructing clmul operands.
#foreign pub fn v128_from_u64(v: u64) Vec128

// Store 16 bytes from a vector to a pointer (unaligned).
#foreign pub fn v128_store(ptr: &u8, a: Vec128) void

// Bitwise NOT: result[i] = ~a[i]
#foreign pub fn v128_not(a: Vec128) Vec128

// Byte shuffle / table lookup: result[i] = a[idx[i] & 0x0F].
// If idx[i] has the high bit set, result[i] = 0 (matches PSHUFB / TBL behavior).
// Used for nibble-based classification: build a 16-entry lookup table as a Vec128,
// then use each byte's nibble value as an index to classify 16 bytes in parallel.
#foreign pub fn v128_shuffle(a: Vec128, idx: Vec128) Vec128

// Right-shift each u8 lane by an immediate value: result[i] = a[i] >> imm.
// Used to extract high nibbles (shift by 4) for nibble classification.
#foreign pub fn v128_shr_u8(a: Vec128, imm: u8) Vec128

// Carryless multiplication of the low 64 bits of each vector.
// Produces a 128-bit result. On x86 this is PCLMULQDQ (imm=0x00),
// on ARM this is PMULL. Used to compute prefix XOR in a single
// instruction for quote-parity tracking in SIMD parsers.
#foreign pub fn v128_clmul(a: Vec128, b: Vec128) Vec128

// =============================================================================
// Tests
// =============================================================================

test "v128_store round-trips through load" {
    const src = v128_splat_u8(0xAB)
    let buf: [u8; 16] = [0; 16]
    v128_store(&buf[0], src)
    const loaded = v128_load(&buf[0])
    assert_eq(v128_movemask(v128_cmpeq_u8(loaded, src)), 65535u32, "all lanes should match")
}

test "v128_not inverts all bits" {
    const a = v128_splat_u8(0x0F)
    const b = v128_not(a)
    const expected = v128_splat_u8(0xF0)
    assert_eq(v128_movemask(v128_cmpeq_u8(b, expected)), 65535u32, "NOT 0x0F should be 0xF0")
}

test "v128_shuffle performs table lookup" {
    let table_data: [u8; 16] = [0; 16]
    table_data[0] = 0
    table_data[1] = 10
    table_data[2] = 20
    table_data[3] = 30
    const table = v128_load(&table_data[0])
    let idx_data: [u8; 16] = [0; 16]
    idx_data[0] = 3
    idx_data[1] = 1
    idx_data[2] = 0
    idx_data[3] = 2
    const idx = v128_load(&idx_data[0])
    const result = v128_shuffle(table, idx)
    let out: [u8; 16] = [0; 16]
    v128_store(&out[0], result)
    assert_eq(out[0] as u32, 30u32, "index 3 -> 30")
    assert_eq(out[1] as u32, 10u32, "index 1 -> 10")
    assert_eq(out[2] as u32, 0u32, "index 0 -> 0")
    assert_eq(out[3] as u32, 20u32, "index 2 -> 20")
}

test "v128_shuffle zeros lane when high bit set" {
    const table = v128_splat_u8(0xFF)
    let idx_data: [u8; 16] = [0; 16]
    idx_data[0] = 0x80
    const idx = v128_load(&idx_data[0])
    const result = v128_shuffle(table, idx)
    let out: [u8; 16] = [0; 16]
    v128_store(&out[0], result)
    assert_eq(out[0] as u32, 0u32, "high-bit index should zero the lane")
}

test "v128_shr_u8 shifts each lane" {
    const a = v128_splat_u8(0xF0)
    const b = v128_shr_u8(a, 4)
    const expected = v128_splat_u8(0x0F)
    assert_eq(v128_movemask(v128_cmpeq_u8(b, expected)), 65535u32, "0xF0 >> 4 should be 0x0F")
}

test "v128_clmul prefix xor pattern" {
    const input = v128_from_u64(1 as u64)
    const all_ones = v128_from_u64(0xFFFF_FFFF_FFFF_FFFF)
    const result = v128_clmul(input, all_ones)
    let out: [u8; 16] = [0; 16]
    v128_store(&out[0], result)
    assert_eq(out[0] as u32, 255u32, "byte 0 should be 0xFF")
    assert_eq(out[1] as u32, 255u32, "byte 1 should be 0xFF")
    assert_eq(out[7] as u32, 255u32, "byte 7 should be 0xFF")
}

test "v128_from_u64x2 packs correctly" {
    const v = v128_from_u64x2(0x01020304_05060708, 0x090A0B0C_0D0E0F10)
    let out: [u8; 16] = [0; 16]
    v128_store(&out[0], v)
    assert_eq(out[0] as u32, 8u32, "low byte of lo")
    assert_eq(out[8] as u32, 16u32, "low byte of hi")
}

test "v128_from_u32x4 packs correctly" {
    const v = v128_from_u32x4(0x0102_0304 as u32, 0x0506_0708 as u32, 0x090A_0B0C as u32, 0x0D0E_0F10 as u32)
    let out: [u8; 16] = [0; 16]
    v128_store(&out[0], v)
    assert_eq(out[0] as u32, 4u32, "low byte of first u32")
    assert_eq(out[4] as u32, 8u32, "low byte of second u32")
    assert_eq(out[8] as u32, 12u32, "low byte of third u32")
    assert_eq(out[12] as u32, 16u32, "low byte of fourth u32")
}

test "v128_from_u64 zeros high bits" {
    const v = v128_from_u64(255 as u64)
    let out: [u8; 16] = [0; 16]
    v128_store(&out[0], v)
    assert_eq(out[0] as u32, 255u32, "low byte set")
    assert_eq(out[8] as u32, 0u32, "high half should be zero")
}
