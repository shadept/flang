//! TEST: bitwise_u64
//! EXIT: 255
pub fn main() i32 {
    let mask: u64 = 255u64         // 0xFF (lower 8 bits)
    let val: u64 = 65280u64        // 0xFF00 (bits 8-15 set)
    let result = val | mask        // Should be 0xFFFF = 65535
    let masked = result & mask     // Should be 0xFF = 255
    return masked as i32
}
