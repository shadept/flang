//! TEST: error_e1004_invalid_array_length
//! COMPILE-ERROR: E1004

pub fn main() i32 {
    let arr: [i32; "five"] = [1, 2, 3, 4, 5]  // ERROR: array length must be an integer literal
    return 0
}
