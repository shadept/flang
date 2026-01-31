//! TEST: void_return_test
//! EXIT: 3

import std.mem

pub fn set_value(ptr: &i32) {
    let a: i32 = 1
    let b: i32 = 0
    let y: i32 = if (a > b) 3 else 2
    // Use memcpy to write the value
    memcpy(ptr as &u8, &y as &u8, 4)
}

pub fn main() i32 {
    let val: i32 = 0
    set_value(&val)
    return val
}
