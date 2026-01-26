//! TEST: array_set_index_multiple
//! EXIT: 15

pub fn main() i32 {
    let arr: [i32; 4] = [0, 0, 0, 0]
    arr[0] = 1
    arr[1] = 2
    arr[2] = 4
    arr[3] = 8
    return arr[0] + arr[1] + arr[2] + arr[3]
}
