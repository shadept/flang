//! TEST: select_wait_twice
//! EXIT: 1
//! STDOUT: select: `wait` called twice

// A second `wait` in one select panics instead of running the winner's handler again.

import std.channel
import std.result
import std.task

pub fn main() i32 {
    let ch: Channel(i32) = channel(1)
    let _seed: Result((), TrySendError(i32)) = ch.try_send(1)
    const v: i32 = select {
        on(ch.recv()) { it ?? 0 }
        on.wait()
        on.wait() // panic: select: `wait` called twice
    }
    return v
}
