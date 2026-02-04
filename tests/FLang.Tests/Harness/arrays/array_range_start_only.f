//! TEST: array_range_start_only
//! EXIT: 2

pub fn main() i32 {
    let arr = [10i32, 20, 12]
    let slice = arr[1..]  // [20, 12]
    return slice.len as i32
}
