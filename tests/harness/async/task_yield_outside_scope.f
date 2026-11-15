//! TEST: task_yield_outside_scope
//! EXIT: 1
//! STDOUT: yield_now: outside a concurrent scope

// Yielding outside every scope panics.

import std.task

pub fn main() i32 {
    let _r = yield_now()
    return 0
}
