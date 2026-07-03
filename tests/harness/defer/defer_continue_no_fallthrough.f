//! TEST: defer_continue_no_fallthrough
//! EXIT: 0
//! STDOUT: iter:0
//! STDOUT: body-defer
//! STDOUT: iter:1
//! STDOUT: before-continue
//! STDOUT: inner-defer
//! STDOUT: body-defer
//! STDOUT: iter:2
//! STDOUT: body-defer
//! STDOUT: outer

// Pins that `continue` has no fall-through. `bad_counter` catches any side
// effect from statements lexically after the `continue`: if it's non-zero
// at return, the test fails on exit code.

import core.io

fn emit(tag: String) {
    println(tag)
}

pub fn main() i32 {
    let bad_counter: i32 = 0
    defer emit("outer")

    for i in 0usize..3usize {
        defer emit("body-defer")
        if i == 0usize { emit("iter:0") }
        else if i == 1usize { emit("iter:1") }
        else { emit("iter:2") }

        if i == 1usize {
            defer emit("inner-defer")
            emit("before-continue")
            continue
            bad_counter = bad_counter + 100
            defer emit("post-continue-defer")
            emit("unreachable")
        }
    }

    return bad_counter
}
