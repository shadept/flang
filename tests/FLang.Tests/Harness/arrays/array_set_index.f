//! TEST: array_set_index
//! EXIT: 42

pub fn main() i32 {
    let arr: [i32; 3] = [1, 2, 3]
    arr[1] = 42
    return arr[1]
}
