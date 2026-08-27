//! TEST: shift_count_boundary
//! EXIT: 0

// A literal shift count of width-1 is legal on every integer width, and a
// count wide for the narrow type is fine once the operand is widened first.

pub fn main() i32 {
    let b: u8 = 1
    let hi8: u8 = b << 7
    if hi8 != 0x80 {
        return 1
    }

    let w: u32 = (b as u32) << 18
    if w != 0x40000 {
        return 2
    }

    let q: u64 = 1u64 << 63
    if q == 0 {
        return 3
    }

    let s: u16 = 0x8000
    if (s >> 15) != 1 {
        return 4
    }

    return 0
}
