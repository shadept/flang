//! TEST: shift_right_arithmetic
//! EXIT: 0
// >> is arithmetic shift: preserves sign bit for signed types
pub fn main() i32 {
    let a: i32 = -8
    let b: i32 = a >> 1    // -8 >> 1 = -4 (arithmetic shift)
    if (b != -4) { return 1 }
    return 0
}
