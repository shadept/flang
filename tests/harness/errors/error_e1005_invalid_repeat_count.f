//! TEST: error_e1005_invalid_repeat_count
//! COMPILE-ERROR: E2002

pub fn main() i32 {
    let arr: [i32; 5] = [0; "five"]  // ERROR: type mismatch — count must be usize
    return 0
}
