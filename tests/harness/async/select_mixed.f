//! TEST: select_mixed
//! EXIT: 0

// select mixes receive, send and task arms; the first ready arm's handler gives the value, and the
// rest are withdrawn.

import std.channel
import std.result
import std.task

type Event = enum {
    Got(i32)
    Sent
    Finished
    Stopped
}

fn wait_then(rounds: i32, v: i32) i32 {
    for _i in 0..rounds {
        let _y: Result((), Cancelled) = yield_now()
    }
    return v
}

fn next_event(data: &Channel(i32), out: &Channel(i32), worker: &Task(i32)) Event {
    return select {
        on(data.recv()) {
            it match {
                Ok(v) => Event.Got(v)
                Err(_) => Event.Stopped
            }
        }
        on(out.send(1)) { Event.Sent }
        on(worker) { Event.Finished }
        on.wait()
    }
}

fn code(e: Event) i32 {
    return e match {
        Got(v) => v
        Sent => 100
        Finished => 200
        Stopped => 300
    }
}

pub fn main() i32 {
    let data: Channel(i32) = channel(1)
    let out: Channel(i32) = channel()
    const total: i32 = concurrent {
        const worker: Task(i32) = scope.spawn { wait_then(3, 7) }
        let _seed: Result((), TrySendError(i32)) = data.try_send(5)
        const first: i32 = code(next_event(&data, &out, &worker))
        const second: i32 = code(next_event(&data, &out, &worker))
        data.close()
        const third: i32 = code(next_event(&data, &out, &worker))
        first + second + third + worker.await()
    }
    data.deinit()
    out.deinit()
    // 5 buffered, then the worker finishes, then the closed channel reports.
    if total != 5 + 200 + 300 + 7 {
        return 1
    }
    return 0
}
