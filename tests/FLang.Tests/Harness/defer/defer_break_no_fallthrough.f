//! TEST: defer_break_no_fallthrough
//! EXIT: 0
//! STDOUT: loop:0
//! STDOUT: body-defer:0
//! STDOUT: loop:1
//! STDOUT: before-break
//! STDOUT: inner-defer
//! STDOUT: body-defer:1
//! STDOUT: after-loop
//! STDOUT: outer

// Pins that `break` has no fall-through. The `bad_counter` counts side effects
// from statements lexically AFTER the `break`; if any of them execute at
// runtime the exit code goes non-zero and the test fails.
//
// Also checks that defers registered *before* the `break` fire innermost
// first, and that nothing after the `break` — including a trailing `defer`
// — ever registers or emits at runtime.

import core.io

fn emit(tag: String) {
    println(tag)
}

pub fn main() i32 {
    let bad_counter: i32 = 0
    defer emit("outer")

    for i in 0usize..5usize {
        defer emit(if i == 0usize { "body-defer:0" } else { "body-defer:1" })
        emit(if i == 0usize { "loop:0" } else { "loop:1" })

        if i == 1usize {
            defer emit("inner-defer")
            emit("before-break")
            break
            bad_counter = bad_counter + 100
            defer emit("post-break-defer")
            emit("unreachable")
        }
    }

    emit("after-loop")
    return bad_counter
}
