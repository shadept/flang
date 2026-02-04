//! TEST: array_range_end_only
//! EXIT: 2

pub fn main() i32 {
    let arr = [10i32, 20, 12]
    let slice = arr[..2]  // [10, 20]
    return slice.len as i32
}
