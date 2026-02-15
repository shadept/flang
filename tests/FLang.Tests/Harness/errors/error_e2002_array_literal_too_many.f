//! TEST: array_literal_too_many
//! COMPILE-ERROR: E2002 expected 2, got 5

// Array literal has more elements than the declared type
pub fn main() i32 {
    let arr: [i32; 2] = [1, 2, 3, 4, 5]
    return arr.len as i32
}
