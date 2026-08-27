//! TEST: shift_count_too_large_error
//! COMPILE-ERROR: E2121

// A literal shift count at or beyond the shifted operand's width is an error:
// the result has the left operand's type, so nothing of the value survives.

pub fn main() i32 {
    let b: u8 = 0xFF
    let x: u8 = (b & 0x07) << 18
    return x as i32
}
