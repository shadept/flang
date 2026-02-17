//! TEST: float_scientific
//! EXIT: 0
//! STDOUT: 15000000000.000000
//! STDOUT: 0.000300

import core.io

pub fn main() i32 {
    let a: f64 = 1.5e10
    let b: f64 = 3e-4
    println(a)
    println(b)
    return 0
}
