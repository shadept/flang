//! TEST: defer_return_no_fallthrough
//! EXIT: 7
//! STDOUT: before-return
//! STDOUT: inner-defer
//! STDOUT: outer-defer

// Pins that `return` has no fall-through. `run()` returns 7 directly from
// inside a nested if; any statement after the `return` — including the
// trailing `defer` — must not execute. If they did, `poisoned` would be 1
// and exit code would be 8 instead of 7.
//
// Defers registered before the `return` still fire, innermost first.

import core.io

fn emit(tag: String) {
    println(tag)
}

fn run(poisoned_out: &i32) i32 {
    defer emit("outer-defer")
    if true {
        defer emit("inner-defer")
        emit("before-return")
        return 7
        poisoned_out.* = 1
        defer emit("post-return-defer")
        emit("unreachable")
    }
    return 0
}

pub fn main() i32 {
    let poisoned: i32 = 0
    const rc = run(&poisoned)
    return rc + poisoned
}
