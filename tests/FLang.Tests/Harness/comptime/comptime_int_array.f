//! TEST: comptime_int_array
//! EXIT: 6

pub fn main() i32 {
    let arr: [i32; 3] = [1, 2, 3]
    return arr[0] + arr[1] + arr[2]
}
