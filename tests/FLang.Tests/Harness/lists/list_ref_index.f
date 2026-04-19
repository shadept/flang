//! TEST: list_ref_index
//! STDOUT: PASS

import std.list

fn inc(n: &i32) {
    n.* = n.* + 10
}

pub fn main() i32 {
    let xs: List(i32) = list(4)
    defer xs.deinit()
    xs.push(1i32)
    xs.push(2i32)
    xs.push(3i32)

    // `&xs[i]` uses op_index_ref to return &T directly.
    inc(&xs[1])

    if xs[1] != 12 {
        println("FAIL")
        return 1
    }
    println("PASS")
    return 0
}
