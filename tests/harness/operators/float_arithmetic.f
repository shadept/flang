//! TEST: float_arithmetic
//! EXIT: 0
//! STDOUT: 5.5
//! STDOUT: 1.5
//! STDOUT: 7
//! STDOUT: 1.75
//! STDOUT: 1.5

import core.io

pub fn main() i32 {
    let a: f64 = 3.5
    let b: f64 = 2.0
    println(a + b)
    println(a - b)
    println(a * b)
    println(a / b)
    println(a % b)
    return 0
}
