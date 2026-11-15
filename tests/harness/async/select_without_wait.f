//! TEST: select_without_wait
//! EXIT: 1
//! STDOUT: select: the body returned without calling `wait`

// A select body that returns without calling `wait` panics.

import std.channel
import std.result
import std.task

pub fn main() i32 {
    let ch: Channel(i32) = channel(1)
    let _seed: Result((), TrySendError(i32)) = ch.try_send(1)
    const v: i32 = select { on =>
        on(ch.recv()) { it ?? 0 }
    }
    return v
}
