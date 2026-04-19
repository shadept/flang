//! TEST: list_range_index
//! STDOUT: PASS

import std.list

pub fn main() i32 {
    let xs: List(i32) = list(4)
    defer xs.deinit()
    xs.push(10i32)
    xs.push(20i32)
    xs.push(30i32)
    xs.push(40i32)

    let tail = xs[1..]
    let sum: i32 = 0
    for v in tail {
        sum = sum + v
    }
    if sum != 90 {
        println("FAIL tail")
        return 1
    }

    let mid = xs[1..3]
    let sum2: i32 = 0
    for v in mid {
        sum2 = sum2 + v
    }
    if sum2 != 50 {
        println("FAIL mid")
        return 1
    }

    println("PASS")
    return 0
}
