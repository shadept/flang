//! TEST: task_escaped_await
//! EXIT: 1
//! STDOUT: await: the task's scope has ended

// Awaiting a task after its scope has ended panics.

import std.task

fn one() i32 {
    return 1
}

pub fn main() i32 {
    const t: Task(i32) = concurrent(Start.Lazy) { s => s.spawn { one() } }
    return t.await()
}
