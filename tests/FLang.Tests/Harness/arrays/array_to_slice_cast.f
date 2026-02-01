//! TEST: array_to_slice_cast
//! EXIT: 3

// Explicit cast from array to slice
pub fn main() i32 {
    let arr: [i32; 3] = [10, 20, 30]
    let s: i32[] = arr as i32[]
    return s.len as i32
}
