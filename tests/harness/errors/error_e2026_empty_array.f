//! TEST: error_e2026_empty_array
//! COMPILE-ERROR: E2026

pub fn main() i32 {
    let x = []  // ERROR: cannot infer type of empty array literal
    return 0
}
