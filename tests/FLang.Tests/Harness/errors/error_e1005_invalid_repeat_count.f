//! TEST: error_e1005_invalid_repeat_count
//! COMPILE-ERROR: E1005

pub fn main() i32 {
    let arr: [i32; 5] = [0; "five"]  // ERROR: repeat count must be an integer literal
    return 0
}
