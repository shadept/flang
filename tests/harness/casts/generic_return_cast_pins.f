//! TEST: generic_return_cast_pins
//! EXIT: 0
//! STDOUT: 8
//! STDOUT: 4607182418800017408

import core.slice

import std.io.print

pub fn main() i32 {
    let source: [f64; 8] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
    let t = reinterpret(source) as u64[]
    println(t.len)
    println(t[0])
    return 0
}
