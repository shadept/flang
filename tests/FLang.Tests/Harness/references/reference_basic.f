//! TEST: reference_basic
//! EXIT: 42

pub fn main() i32 {
    let x: i32 = 42
    let ptr: &i32 = &x
    let value: i32 = ptr.*
    return value
}
