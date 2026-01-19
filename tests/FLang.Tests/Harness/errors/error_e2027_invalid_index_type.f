//! TEST: error_e2027_invalid_index_type
//! COMPILE-ERROR: E2027

pub fn main() i32 {
    let arr: [i32; 3] = [1, 2, 3]
    let val: i32 = arr[true]  // ERROR: array index must be an integer
    return val
}
