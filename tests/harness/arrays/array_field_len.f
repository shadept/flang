//! TEST: array_field_len
//! EXIT: 5

// Access .len directly on an array
pub fn main() i32 {
    let arr: [i32; 5] = [10, 20, 30, 40, 50]
    return arr.len as i32
}
