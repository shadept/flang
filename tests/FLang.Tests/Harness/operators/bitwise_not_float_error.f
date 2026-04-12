//! TEST: bitwise_not_float_error
//! COMPILE-ERROR: E2017

// ~ on float should be a compile error

pub fn main() i32 {
    let x: f64 = 3.14
    let y: f64 = ~x
    return 0
}
