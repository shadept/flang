// std.simd — portable 128-bit SIMD operations.
//
// Vec128 is a 16-byte value type passed in XMM (x86) or NEON (aarch64) registers.
// Operations map to single instructions on both architectures.

#simd
pub type Vec128 = struct {
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
