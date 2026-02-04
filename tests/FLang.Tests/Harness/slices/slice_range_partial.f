//! TEST: slice_range_partial
//! EXIT: 4

pub fn main() i32 {
    let arr = [1i32, 2, 3, 4, 5]
    let s1: i32[] = arr
    let s2 = s1[1..]  // [2, 3, 4, 5] - length should be 4
    return s2.len as i32
}
