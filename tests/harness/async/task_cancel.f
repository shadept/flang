//! TEST: task_cancel
//! EXIT: 0

// Cancelling a scope reaches its tasks and nested scopes, and a cancelled task's defers run.

import std.result
import std.task

type Log = struct {
    cleaned: i32
    rounds: i32
    inner_saw: bool
}

fn worker(log: &Log) i32 {
    defer log.cleaned = log.cleaned + 1
    loop {
        yield_now() ?? return 1
        log.rounds = log.rounds + 1
    }
}

fn nested_watcher(log: &Log) i32 {
    return concurrent { inner =>
        inner
            .spawn {
                loop {
                    yield_now() ?? break
                }
                log.inner_saw = context.job.is_cancelled()
                2
            }
            .await()
    }
}

fn cancel_after_rounds(s: &Scope) i32 {
    for _i in 0i32..3i32 {
        let _y = yield_now()
    }
    s.cancel()
    return 4
}

pub fn main() i32 {
    let log: Log = Log { cleaned = 0, rounds = 0, inner_saw = false }
    const total: i32 = concurrent { s =>
        const w: Task(i32) = s.spawn { worker(&log) }
        const n: Task(i32) = s.spawn { nested_watcher(&log) }
        const c: Task(i32) = s.spawn { cancel_after_rounds(s) }
        w.await() + n.await() + c.await()
    }
    if total != 7 {
        return 1
    }
    if log.cleaned != 1 {
        return 2
    }
    if log.rounds < 1 {
        return 3
    }
    if !log.inner_saw {
        return 4
    }
    if context.job.is_cancelled() {
        return 5
    }
    return 0
}
