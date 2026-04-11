// core.bits — scalar bit manipulation intrinsics.
//
// Portable wrappers for hardware bit-counting instructions:
//   - x86_64: LZCNT, TZCNT, POPCNT
//   - aarch64: CLZ, RBIT+CLZ, CNT
//   - Scalar fallback otherwise

import std.test

// Count leading zero bits in a 32-bit integer.
// Returns 32 when the input is 0.
#foreign pub fn leading_zeros_u32(v: u32) u32

// Count leading zero bits in a 64-bit integer.
// Returns 64 when the input is 0.
#foreign pub fn leading_zeros_u64(v: u64) u64

// Count trailing zero bits in a 32-bit integer.
// Returns 32 when the input is 0.
#foreign pub fn trailing_zeros_u32(v: u32) u32

// Count trailing zero bits in a 64-bit integer.
// Returns 64 when the input is 0.
#foreign pub fn trailing_zeros_u64(v: u64) u64

// Count the number of set bits (population count) in a 32-bit integer.
#foreign pub fn count_ones_u32(v: u32) u32

// Count the number of set bits (population count) in a 64-bit integer.
#foreign pub fn count_ones_u64(v: u64) u64

// =============================================================================
// Tests
// =============================================================================

test "leading_zeros_u32 basic cases" {
    assert_eq(leading_zeros_u32(0 as u32), 32u32, "zero has 32 leading zeros")
    assert_eq(leading_zeros_u32(1 as u32), 31u32, "1 has 31 leading zeros")
    assert_eq(leading_zeros_u32(0x8000_0000 as u32), 0u32, "high bit set has 0 leading zeros")
    assert_eq(leading_zeros_u32(0x0000_FFFF as u32), 16u32, "16-bit value has 16 leading zeros")
}

test "leading_zeros_u64 basic cases" {
    assert_eq(leading_zeros_u64(0 as u64) as u32, 64u32, "zero has 64 leading zeros")
    assert_eq(leading_zeros_u64(1 as u64) as u32, 63u32, "1 has 63 leading zeros")
}

test "trailing_zeros_u32 basic cases" {
    assert_eq(trailing_zeros_u32(0 as u32), 32u32, "zero has 32 trailing zeros")
    assert_eq(trailing_zeros_u32(1 as u32), 0u32, "1 has 0 trailing zeros")
    assert_eq(trailing_zeros_u32(0x8000_0000 as u32), 31u32, "high bit has 31 trailing zeros")
    assert_eq(trailing_zeros_u32(8 as u32), 3u32, "8 has 3 trailing zeros")
}

test "trailing_zeros_u64 basic cases" {
    assert_eq(trailing_zeros_u64(0 as u64) as u32, 64u32, "zero has 64 trailing zeros")
    assert_eq(trailing_zeros_u64(16 as u64) as u32, 4u32, "16 has 4 trailing zeros")
}

test "count_ones_u32 basic cases" {
    assert_eq(count_ones_u32(0 as u32), 0u32, "zero has 0 bits set")
    assert_eq(count_ones_u32(0xFFFF_FFFF as u32), 32u32, "all ones has 32 bits set")
    assert_eq(count_ones_u32(0xAAAA_AAAA as u32), 16u32, "alternating bits has 16 set")
    assert_eq(count_ones_u32(7 as u32), 3u32, "7 has 3 bits set")
}

test "count_ones_u64 basic cases" {
    assert_eq(count_ones_u64(0 as u64) as u32, 0u32, "zero has 0 bits set")
    assert_eq(count_ones_u64(0xFFFF_FFFF_FFFF_FFFF as u64) as u32, 64u32, "all ones has 64 bits set")
}
