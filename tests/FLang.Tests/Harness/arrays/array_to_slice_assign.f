//! TEST: array_to_slice_assign
//! EXIT: 4

// Implicit coercion from array to slice via variable assignment
pub fn main() i32 {
    let s: u8[] = [1, 2, 3, 4]
    return s.len as i32
}
