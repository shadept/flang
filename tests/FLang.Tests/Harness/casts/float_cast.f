//! TEST: float_cast
//! EXIT: 3
//! STDOUT: 42.000000
//! STDOUT: 1.000000

import core.io

pub fn main() i32 {
    // int -> float
    let i: i32 = 42
    let f: f64 = i as f64
    println(f)

    // f32 -> f64 widening
    let x: f32 = 1.0f32
    let y: f64 = x as f64
    println(y)

    // float -> int
    let pi: f64 = 3.7
    return pi as i32
}
