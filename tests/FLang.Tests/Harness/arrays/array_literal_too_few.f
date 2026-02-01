//! TEST: array_literal_too_few
//! COMPILE-ERROR: E2002

// Array literal has fewer elements than the declared type
pub fn main() i32 {
    let arr: [i32; 5] = [1, 2, 3]
    return arr.len as i32
}
