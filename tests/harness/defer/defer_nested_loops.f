//! TEST: defer_nested_loops
//! EXIT: 0
//! STDOUT: i=0 j=0
//! STDOUT: inner-defer
//! STDOUT: i=0 j=1
//! STDOUT: inner-break
//! STDOUT: inner-defer
//! STDOUT: outer-body
//! STDOUT: i=1 j=0
//! STDOUT: inner-defer
//! STDOUT: i=1 j=1
//! STDOUT: inner-break
//! STDOUT: inner-defer
//! STDOUT: outer-body
//! STDOUT: function-defer

// Pins that `break` and `continue` target only the innermost loop: when the
// inner loop breaks, only defers inside the inner body fire. The outer-loop
// `defer emit("outer-body")` and the function-level `defer emit("function-defer")`
// must NOT fire during the inner break — they fire at their own scope exits
// (each outer iteration end, and the final function return, respectively).

import core.io

fn emit(tag: String) {
    println(tag)
}

pub fn main() i32 {
    defer emit("function-defer")

    for i in 0usize..2usize {
        defer emit("outer-body")

        for j in 0usize..5usize {
            defer emit("inner-defer")
            if i == 0usize and j == 0usize { emit("i=0 j=0") }
            else if i == 0usize and j == 1usize { emit("i=0 j=1") }
            else if i == 1usize and j == 0usize { emit("i=1 j=0") }
            else if i == 1usize and j == 1usize { emit("i=1 j=1") }

            if j == 1usize {
                emit("inner-break")
                break
            }
        }
    }

    return 0
}
