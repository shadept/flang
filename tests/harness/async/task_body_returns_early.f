//! TEST: task_body_returns_early
//! EXIT: 1
//! STDOUT: concurrent: the body returned while a task still runs; await or join first

// A scope body that returns while one of its tasks still runs panics.

import std.task

fn noop() {}

pub fn main() i32 {
    concurrent { scope.launch { noop() } }
    return 0
}
