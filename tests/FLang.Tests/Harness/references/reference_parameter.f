//! TEST: reference_parameter
//! EXIT: 10

pub fn getValue(ptr: &i32) i32 {
    return ptr.*
}

pub fn main() i32 {
    let x: i32 = 10
    return getValue(&x)
}
