//! TEST: array_range_full
//! EXIT: 3

pub fn main() i32 {
    let arr = [10i32, 20, 12]
    let slice = arr[0..3]
    return slice.len as i32
}
