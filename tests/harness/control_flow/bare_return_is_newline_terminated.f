//! TEST: bare_return_is_newline_terminated
//! STDOUT: early
//! STDOUT: void_call
//! EXIT: 0
import core.io

pub fn gate() bool {
    return false
}

// A `return` alone on its line takes no operand: the `if` below opens the next statement and is
// unreachable, so nothing after the return runs.
pub fn early() {
    println("early")
    return

    if !gate() {
        println("gate")
    }
    println("tail")
}

pub fn noisy() {
    println("void_call")
}

// A void function may return a void-typed expression; the call still happens.
pub fn forwards() {
    return noisy()
}

pub fn main() i32 {
    early()
    forwards()
    return 0
}
