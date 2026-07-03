//! TEST: bitwise_not_bool_error
//! COMPILE-ERROR: E2017

// ~ on bool should be a compile error

pub fn main() i32 {
    let x: bool = true
    let y: bool = ~x
    return 0
}
