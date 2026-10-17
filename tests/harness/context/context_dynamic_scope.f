//! TEST: context_dynamic_scope
//! STDOUT: 0
//! STDOUT: 1
//! STDOUT: 2
//! STDOUT: 1
//! STDOUT: 0
//! EXIT: 0

// A callee runs under its caller's context at the time of the call, and a rebind lasts exactly as
// long as its body.

import std.io.print

context depth: u32 = 0

fn show() {
    println(context.depth)
}

fn descend() {
    context(depth = context.depth + 1) {
        show()
    }
}

pub fn main() i32 {
    show()
    context(depth = 1u32) {
        show()
        descend()
        show()
    }
    show()
    return 0
}
