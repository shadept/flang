//! TEST: array_range_unbounded
//! EXIT: 3

pub fn main() i32 {
    let arr = [10i32, 20, 12]
    let slice = arr[..]  // full shallow copy
    return slice.len as i32
}
