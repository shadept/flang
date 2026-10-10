//! TEST: void_return_test
//! EXIT: 3

pub fn set_value(ptr: &i32) {
    let a: i32 = 1
    let b: i32 = 0
    let y: i32 = if (a > b) { 3 } else { 2 }
    ptr.* = y
}

pub fn main() i32 {
    let val: i32 = 0
    set_value(&val)
    return val
}
