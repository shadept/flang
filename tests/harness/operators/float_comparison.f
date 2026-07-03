//! TEST: float_comparison
//! EXIT: 0
//! STDOUT: 1
//! STDOUT: 0
//! STDOUT: 1
//! STDOUT: 0
//! STDOUT: 1
//! STDOUT: 1

import core.io

pub fn check(v: bool) i32 {
    if v { return 1 }
    return 0
}

pub fn main() i32 {
    let a: f64 = 3.14
    let b: f64 = 2.71
    println(check(a > b))
    println(check(a < b))
    println(check(a != b))
    println(check(a == b))
    println(check(a >= 3.14))
    println(check(b <= 2.71))
    return 0
}
