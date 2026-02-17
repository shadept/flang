//! TEST: float_arithmetic
//! EXIT: 0
//! STDOUT: 5.500000
//! STDOUT: 1.500000
//! STDOUT: 7.000000
//! STDOUT: 1.750000
//! STDOUT: 1.500000

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
