//! TEST: task_scopes
//! EXIT: 0

// Await returns results, tasks see their scope's context, scopes nest, join waits for launched
// tasks, and a lazy task runs only once awaited.

import std.task

pub context tag: i32 = 0

fn add(a: i32, b: i32) i32 {
    return a + b
}

fn twenty() i32 {
    return 20
}

pub fn main() i32 {
    const sum: i32 = concurrent {
        const a: Task(i32) = scope.spawn { add(1, 2) }
        const b: Task(i32) = scope.spawn { add(3, 4) }
        a.await() + b.await()
    }
    if sum != 10 {
        return 1
    }

    let seen: i32 = 0
    context(tag = 7) {
        seen = concurrent {
            scope
                .spawn { context.tag }
                .await()
        }
    }
    if seen != 7 {
        return 2
    }

    const nested: i32 = concurrent {
        const outer: Task(i32) = scope.spawn { concurrent { scope.spawn { twenty() }.await() + 1 } }
        outer.await()
    }
    if nested != 21 {
        return 3
    }

    let hits: i32 = 0
    const joined: i32 = concurrent {
        scope.launch { hits = hits + 1 }
        scope.launch { hits = hits + 10 }
        scope.join()
        hits
    }
    if joined != 11 {
        return 4
    }

    let ran: i32 = 0
    const lazy: i32 = concurrent(Start.Lazy) {
        const t: Task(i32) = scope.spawn {
            ran = ran + 1
            5
        }
        const before: i32 = ran
        before * 100 + t.await()
    }
    if lazy != 5 or ran != 1 {
        return 5
    }
    return 0
}
