//! TEST: array_field_ptr
//! EXIT: 10

// Access .ptr on an array and dereference it to get the first element
pub fn main() i32 {
    let arr: [i32; 3] = [10, 20, 30]
    let p = arr.ptr
    return p.*
}
